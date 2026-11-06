// SPDX-License-Identifier: GPL-3.0-or-later
// Compressing ROMs (.nds -> .ndz), as openfpga-PlayStation's plugin converts discs
// (its convert.rs):
// - Keep writes the .ndz next to the .nds.
// - Replace also removes the .nds, but only after the .ndz is written,
//   synced, read back and decompressed to exactly the .nds.
// - When the card has no room for the .ndz next to the .nds, Replace
//   compresses into the plugin's folder on the computer, writes a journal,
//   removes the .nds and copies the .ndz over. A stopped run is finished by
//   the next one (resume); if the copy fails, the .ndz stays on the computer.

use crate::card::*;
use crate::formats;
use crate::games::{find_games, Game};
use std::fs;
use std::io::{self, BufReader};
use std::path::{Path, PathBuf};

/// The plugin's own folder on the computer, under the names hosts give it.
const TEMP_ROOTS: [&str; 2] = ["host", "computer"];
const TEMP_FOLDER: &str = "DS Conversions";
const JOURNAL: &str = "journal.json";

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Mode {
    Keep,
    Replace,
}

pub struct Job {
    pub nds: PathBuf,
    pub ndz: PathBuf,
    pub bytes: u64,
}

/// ROMs in Assets/<platform>/common without a sound .ndz.
pub fn plan(card: &Path, platform: &str) -> Vec<Job> {
    let common = card.join("Assets").join(platform).join("common");
    find_games(&common)
        .into_iter()
        .filter(|g| g.nds.is_some() && !g.ndz_ok())
        .map(|g: Game| {
            let nds = g.nds.unwrap();
            Job { bytes: size(&nds).unwrap_or(0), ndz: g.folder.join(format!("{}.ndz", g.name)), nds }
        })
        .collect()
}

fn temp_root() -> Option<PathBuf> { TEMP_ROOTS.iter().map(PathBuf::from).find(|p| p.is_dir()) }

/// Tests stop the plugin at a named step (config test_stop_at) to check
/// that the next run finishes the job.
fn test_stop(step: &str) {
    if crate::config("test_stop_at").as_deref() == Some(step) {
        panic!("stopped at {step} (test)");
    }
}

/// Write nds compressed to ndz; the file is checked against nds before it
/// gets its name. Returns the .ndz size.
fn compress_to(nds: &Path, ndz: &Path, log: &mut dyn FnMut(&str)) -> Result<u64, String> {
    let rom_size = size(nds).ok_or("the ROM went away")?;
    if rom_size > u32::MAX as u64 {
        return Err("larger than 4 GB".into());
    }
    let open = || fs::File::open(nds).map(|f| BufReader::with_capacity(1 << 20, f)).map_err(reason);
    let step = (rom_size / 4).max(1);
    let mut shown = 0;
    let mut progress = |what: &str, done: u64, log: &mut dyn FnMut(&str)| {
        if done / step > shown && done < rom_size {
            shown = done / step;
            log(&format!("  {what} {} of {} MB", mb(done), mb(rom_size)));
        }
    };
    let plan = formats::plan_ndz(&mut open()?, rom_size, &mut |d| progress("compressing:", d, log)).map_err(reason)?;
    let bytes = plan.file_size();
    log(&format!("  {} MB -> {} MB ({:.2}x), writing", mb(rom_size), mb(bytes), rom_size as f64 / bytes as f64));
    let mut src = open()?;
    write_checked(
        ndz,
        Some(bytes),
        &mut |out| formats::write_ndz(&mut src, &plan, out, &mut |_| {}),
        Some(&mut |file: &mut fs::File| {
            // decompress what is on the card and compare with the ROM
            let mut back = vec![];
            struct Compare<'a> {
                rom: &'a mut dyn io::Read,
                buf: &'a mut Vec<u8>,
            }
            impl io::Write for Compare<'_> {
                fn write(&mut self, data: &[u8]) -> io::Result<usize> {
                    self.buf.resize(data.len(), 0);
                    self.rom.read_exact(self.buf)?;
                    if self.buf[..] != data[..] {
                        return Err(io::Error::other("the compressed ROM decompresses differently from the original"));
                    }
                    Ok(data.len())
                }
                fn flush(&mut self) -> io::Result<()> { Ok(()) }
            }
            let mut rom = open().map_err(io::Error::other)?;
            formats::decompress_ndz(&mut BufReader::with_capacity(1 << 20, file), &mut Compare { rom: &mut rom, buf: &mut back })?;
            Ok(())
        }),
    )
    .map_err(reason)?;
    Ok(bytes)
}

/// The journal of a compression made on the computer: written once the .ndz
/// there is complete, before anything on the card changes. Paths are below
/// the card.
#[derive(serde::Serialize, serde::Deserialize)]
struct Journal {
    nds: String,
    ndz: String,
}

fn through_computer(card: &Path, job: &Job, temp: &Path, log: &mut dyn FnMut(&str)) -> Result<u64, String> {
    let work = temp.join(TEMP_FOLDER).join(stem(&name_of(&job.nds)));
    if work.join(JOURNAL).exists() {
        return Err(format!("an earlier compression is still waiting to be copied back, in the plugin's folder under \"{TEMP_FOLDER}/{}\"", name_of(&work)));
    }
    let _ = fs::remove_dir_all(&work); // unfinished: the original is still on the card
    log("  the SD card is short of space: compressing on the computer first");
    let made = work.join("files").join(name_of(&job.ndz));
    let bytes = compress_to(&job.nds, &made, log).inspect_err(|_| {
        let _ = fs::remove_dir_all(&work);
    })?;
    if !has_room(card, bytes.saturating_sub(job.bytes)) {
        let _ = fs::remove_dir_all(&work);
        return Err(no_space(bytes.saturating_sub(job.bytes)).to_string());
    }
    let journal = Journal { nds: rel(&job.nds, card), ndz: rel(&job.ndz, card) };
    let text = serde_json::to_string_pretty(&journal).map_err(|e| e.to_string())?;
    write_bytes(&work.join(JOURNAL), text.as_bytes()).map_err(reason)?;
    test_stop("journal");
    finish(card, &work, &journal, log)?;
    Ok(bytes)
}

/// Carry out a journal: remove the .nds, copy the .ndz to the card (written,
/// synced and read back), drop the work folder. Every step can be repeated.
fn finish(card: &Path, work: &Path, journal: &Journal, log: &mut dyn FnMut(&str)) -> Result<(), String> {
    let made = work.join("files").join(name_of(Path::new(&journal.ndz)));
    let (nds, ndz) = (card.join(&journal.nds), card.join(&journal.ndz));
    if !same_file(&made, &ndz) {
        if nds.exists() {
            fs::remove_file(&nds).map_err(|e| format!("{}: {e}", name_of(&nds)))?;
        }
        test_stop("remove");
        let bytes = size(&made).unwrap_or(0);
        write_checked(&ndz, Some(bytes), &mut |w| copy_range(&made, 0, bytes, w), None).map_err(|e| {
            format!(
                "copying back to the SD card failed ({}); the original is removed and the compressed ROM is kept on \
                 the computer, in the plugin's folder under \"{TEMP_FOLDER}/{}\". The next run copies it back.",
                reason(e),
                name_of(work)
            )
        })?;
        test_stop("copied");
    } else if nds.exists() {
        fs::remove_file(&nds).map_err(|e| format!("{}: {e}", name_of(&nds)))?;
    }
    let _ = fs::remove_dir_all(work);
    log(&format!("  removed the original {}", name_of(&nds)));
    Ok(())
}

/// Finish compressions a stopped run left in the computer's folder; folders
/// without a journal never touched the card and go. Runs before anything else.
pub fn resume(card: &Path, log: &mut dyn FnMut(&str)) {
    let Some(temp) = temp_root() else { return };
    let Ok(entries) = fs::read_dir(temp.join(TEMP_FOLDER)) else { return };
    for work in entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
        let Ok(text) = fs::read_to_string(work.join(JOURNAL)) else {
            let _ = fs::remove_dir_all(&work); // stopped while compressing; the original is on the card
            continue;
        };
        let Ok(journal) = serde_json::from_str::<Journal>(&text) else {
            log(&format!("could not read {TEMP_FOLDER}/{}/{JOURNAL}; its files are left there", name_of(&work)));
            continue;
        };
        log(&format!("Finishing the compression of {} that an earlier run left part-way", journal.nds));
        let made = work.join("files").join(name_of(Path::new(&journal.ndz)));
        let needed = size(&made).unwrap_or(0).saturating_sub(size(&card.join(&journal.nds)).unwrap_or(0));
        if !has_room(card, needed) {
            log(&format!("  {}; the file stays in the plugin's folder under \"{TEMP_FOLDER}/{}\"", no_space(needed), name_of(&work)));
            continue;
        }
        if let Err(e) = finish(card, &work, &journal, log) {
            log(&format!("  {e}"));
        }
    }
}

fn run_job(card: &Path, job: &Job, mode: Mode, temp: Option<&Path>, log: &mut dyn FnMut(&str)) -> Result<u64, String> {
    match compress_to(&job.nds, &job.ndz, log) {
        Ok(bytes) => {
            if mode == Mode::Replace {
                test_stop("before-remove");
                fs::remove_file(&job.nds).map_err(|e| format!("{}: {e}", name_of(&job.nds)))?;
                log(&format!("  removed the original {}", name_of(&job.nds)));
            }
            Ok(bytes)
        }
        Err(e) => match (e.starts_with(NO_SPACE), mode, temp) {
            (true, Mode::Replace, Some(temp)) => through_computer(card, job, temp, log),
            (true, Mode::Keep, _) => Err(format!("{e}; compressing with \"Replace the Originals\" needs less")),
            _ => Err(e),
        },
    }
}

/// Compress the planned ROMs; returns (done, failed).
pub fn run(card: &Path, platform: &str, jobs: &[Job], mode: Mode, log: &mut dyn FnMut(&str)) -> (usize, usize) {
    let common = card.join("Assets").join(platform).join("common");
    let temp = temp_root();
    let (mut done, mut failed, mut before, mut after) = (0, 0, 0, 0);
    for job in jobs {
        log(&format!("compressing {}", rel(&job.nds, &common)));
        match run_job(card, job, mode, temp.as_deref(), log) {
            Ok(bytes) => {
                done += 1;
                before += job.bytes;
                after += bytes;
            }
            Err(e) => {
                log(&format!("  skip {}: {e}", rel(&job.nds, &common)));
                failed += 1;
            }
        }
    }
    if done > 0 {
        log(&format!("{done} ROMs compressed: {} MB -> {} MB ({:.2}x), {failed} failed", mb(before), mb(after), before as f64 / after.max(1) as f64));
    } else {
        log(&format!("no ROMs compressed, {failed} failed"));
    }
    (done, failed)
}
