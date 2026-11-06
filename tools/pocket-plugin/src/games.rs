// SPDX-License-Identifier: GPL-3.0-or-later
// Game files for the DS core on an Analogue Pocket SD card
// (docs/pocket-plugin.md):
// - <game>.ndt next to every ROM in Assets/nds/common: the ROM tables;
// - Assets/nds/<core>/<game>.json: the game file that loads the ROM and its
//   tables, for cores whose data.json has the slots for it;
// - optionally <game>.ndz: the ROM compressed, for cores that read it.

use crate::card::*;
use crate::formats::{self, NdzInfo};
use crate::rom::{self, BLOCK, BLOCK_SHIFT};
use std::fs;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub const PLATFORMS: [&str; 2] = ["ds", "nds"];

fn read_json(path: &Path) -> Option<serde_json::Value> { serde_json::from_slice(&fs::read(path).ok()?).ok() }

/// A DS core on the card and the data slots its game files fill.
#[derive(Clone, Debug, Default)]
pub struct Core {
    pub id: String,
    pub platform: String,
    /// The slot that takes game files (.json), the ROM's slot and the tables' slot.
    pub instance_slot: Option<i64>,
    pub rom_slot: Option<i64>,
    pub tables_slot: Option<i64>,
    /// The save slot (nonvolatile, .sav): the game file names
    /// Saves/<platform>/common/<game>.sav in it.
    pub save_slot: Option<i64>,
    /// The ROM slot takes .ndz files.
    pub reads_ndz: bool,
}

impl Core {
    /// Whether game files can be made for this core.
    pub fn takes_game_files(&self) -> bool { self.instance_slot.is_some() && self.rom_slot.is_some() }
}

fn slot_id(v: &serde_json::Value) -> Option<i64> {
    match v {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            Some(hex) => i64::from_str_radix(hex, 16).ok(),
            None => s.parse().ok(),
        },
        _ => None,
    }
}

pub fn read_core(card: &Path, id: &str, platform: &str) -> Core {
    let mut core = Core { id: id.into(), platform: platform.into(), ..Default::default() };
    let data = read_json(&card.join("Cores").join(id).join("data.json"));
    let slots = data.as_ref().and_then(|d| d.get("data")?.get("data_slots")?.as_array().cloned()).unwrap_or_default();
    let exts = |s: &serde_json::Value| -> Vec<String> {
        s.get("extensions").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|e| e.as_str().map(|e| e.to_ascii_lowercase())).collect()).unwrap_or_default()
    };
    for s in &slots {
        let (Some(id), e) = (s.get("id").and_then(slot_id), exts(s)) else { continue };
        let has = |x: &str| e.iter().any(|v| v == x);
        if has("json") && core.instance_slot.is_none() {
            core.instance_slot = Some(id);
        } else if has("nds") && core.rom_slot.is_none() {
            core.rom_slot = Some(id);
            core.reads_ndz = has("ndz");
        } else if has("ndt") && core.tables_slot.is_none() {
            core.tables_slot = Some(id);
        } else if has("sav") && s.get("nonvolatile").and_then(|v| v.as_bool()) == Some(true) && core.save_slot.is_none() {
            core.save_slot = Some(id);
        }
    }
    core
}

/// DS cores on the card, sorted by folder name.
pub fn find_cores(card: &Path) -> Vec<Core> {
    let mut found = vec![];
    let Ok(entries) = fs::read_dir(card.join("Cores")) else { return found };
    for entry in entries.flatten() {
        if !entry.file_type().map_or(false, |t| t.is_dir()) {
            continue;
        }
        let id = entry.file_name().to_string_lossy().into_owned();
        let platform = read_json(&entry.path().join("core.json"))
            .and_then(|v| v.get("core")?.get("metadata")?.get("platform_ids")?.get(0)?.as_str().map(String::from));
        if let Some(platform) = platform.filter(|p| PLATFORMS.contains(&p.as_str())) {
            found.push(read_core(card, &id, &platform));
        }
    }
    found.sort_by(|a, b| a.id.cmp(&b.id));
    found
}

// ---- reading a ROM or a compressed ROM --------------------------------------

/// Random access to the original bytes of a .ndz.
pub struct NdzReader {
    file: fs::File,
    pub info: NdzInfo,
    pos: u64,
    cached: Option<(u64, Vec<u8>)>,
}

impl NdzReader {
    pub fn open(path: &Path) -> io::Result<NdzReader> {
        let mut file = fs::File::open(path)?;
        let info = formats::read_ndz_header(&mut io::BufReader::new(&mut file))?;
        Ok(NdzReader { file, info, pos: 0, cached: None })
    }

    fn block(&mut self, b: u64) -> io::Result<&[u8]> {
        if self.cached.as_ref().map(|c| c.0) != Some(b) {
            let (s, e) = (self.info.index[b as usize] as u64, self.info.index[b as usize + 1] as u64);
            let mut stored = vec![0u8; (e - s) as usize];
            self.file.seek(SeekFrom::Start(s))?;
            self.file.read_exact(&mut stored)?;
            let raw = formats::unpack_block(&stored, formats::block_len(self.info.rom_size, b))
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("block {b}: {e}")))?;
            self.cached = Some((b, raw));
        }
        Ok(&self.cached.as_ref().unwrap().1)
    }
}

impl Read for NdzReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.info.rom_size || buf.is_empty() {
            return Ok(0);
        }
        let (b, at) = (self.pos >> BLOCK_SHIFT, (self.pos & (BLOCK - 1)) as usize);
        let data = self.block(b)?;
        let n = (data.len() - at).min(buf.len());
        buf[..n].copy_from_slice(&data[at..at + n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for NdzReader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        self.pos = match to {
            SeekFrom::Start(p) => p,
            SeekFrom::End(d) => (self.info.rom_size as i64 + d) as u64,
            SeekFrom::Current(d) => (self.pos as i64 + d) as u64,
        };
        Ok(self.pos)
    }
}

/// The ROM's tables, from a .nds or a .ndz.
pub fn read_rom(path: &Path) -> io::Result<rom::Rom> {
    if has_ext(&name_of(path), ".ndz") {
        let mut r = NdzReader::open(path)?;
        let size = r.info.rom_size;
        rom::read(&mut r, size)
    } else {
        let size = size(path).unwrap_or(0);
        rom::read(&mut io::BufReader::new(fs::File::open(path)?), size)
    }
}

/// The game code and size of a .nds (to match it with a .ndz).
fn nds_identity(path: &Path) -> Option<(u32, u64)> {
    let mut h = [0u8; 0x10];
    fs::File::open(path).ok()?.read_exact(&mut h).ok()?;
    Some((u32::from_le_bytes(h[0x0C..0x10].try_into().unwrap()), size(path)?))
}

// ---- games -------------------------------------------------------------------

/// One game: a .nds, a .ndz or both, in the same folder with the same name.
#[derive(Debug, Clone)]
pub struct Game {
    pub folder: PathBuf,
    pub name: String,
    pub nds: Option<PathBuf>,
    pub ndz: Option<PathBuf>,
}

impl Game {
    /// A .ndz that holds this game's .nds (or has no .nds next to it).
    pub fn ndz_ok(&self) -> bool {
        let Some(z) = &self.ndz else { return false };
        let Ok(r) = NdzReader::open(z) else { return false };
        match &self.nds {
            None => true,
            Some(n) => nds_identity(n) == Some((r.info.game_code, r.info.rom_size)),
        }
    }

    pub fn ndt(&self) -> PathBuf { self.folder.join(format!("{}.ndt", self.name)) }
}

pub fn find_games(common: &Path) -> Vec<Game> {
    let mut games: Vec<Game> = vec![];
    for path in walk(common, &|n| has_ext(n, ".nds") || has_ext(n, ".ndz")) {
        let file = name_of(&path);
        let name = stem(&file).to_string();
        let folder = path.parent().unwrap().to_path_buf();
        let i = match games.iter().position(|g| g.folder == folder && g.name == name) {
            Some(i) => i,
            None => {
                games.push(Game { folder, name, nds: None, ndz: None });
                games.len() - 1
            }
        };
        if has_ext(&file, ".ndz") { games[i].ndz = Some(path) } else { games[i].nds = Some(path) }
    }
    games
}

/// Python's json.dumps(value, indent=2) for a string: non-ASCII as \uXXXX.
pub fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    out.push_str(&format!("\\u{unit:04x}"));
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn instance_json(data_path: &str, slots: &[(i64, String)]) -> String {
    let slots: Vec<String> =
        slots.iter().map(|(id, filename)| format!("      {{\n        \"id\": {id},\n        \"filename\": {}\n      }}", json_string(filename))).collect();
    format!(
        "{{\n  \"instance\": {{\n    \"magic\": \"APF_VER_1\",\n    \"data_path\": {},\n    \"data_slots\": [\n{}\n    ]\n  }}\n}}\n",
        json_string(data_path),
        slots.join(",\n")
    )
}

#[derive(Default)]
pub struct Summary {
    pub tables: usize,
    pub tables_written: usize,
    pub instances: usize,
    pub failed: usize,
}

/// Write every game's .ndt (when it changed) and, when the core takes them,
/// its game file.
pub fn make_game_files(card: &Path, core: &Core, log: &mut dyn FnMut(&str)) -> Result<Summary, String> {
    let common = card.join("Assets").join(&core.platform).join("common");
    if !common.is_dir() {
        return Err(format!("no Assets/{}/common folder on this card", core.platform));
    }
    let out = card.join("Assets").join(&core.platform).join(&core.id);
    let mut s = Summary::default();
    for game in find_games(&common) {
        // the core's ROM: the .ndz when it reads them and it is sound
        let use_ndz = game.ndz.is_some() && (game.nds.is_none() || core.reads_ndz) && game.ndz_ok();
        let rom_path = if use_ndz { game.ndz.clone().unwrap() } else if let Some(n) = &game.nds { n.clone() } else {
            log(&format!("skip {}: the .ndz can't be read", rel(game.ndz.as_ref().unwrap(), &common)));
            s.failed += 1;
            continue;
        };
        let shown = rel(&rom_path, &common);
        if use_ndz && !core.reads_ndz {
            log(&format!("note: {shown} is compressed, and {} can't read compressed ROMs yet", core.id));
        }
        let rom = match read_rom(&rom_path) {
            Ok(r) => r,
            Err(e) => {
                log(&format!("skip {shown}: {e}"));
                s.failed += 1;
                continue;
            }
        };
        if !rom.header.crc_ok {
            log(&format!("note: {shown}: its header CRC doesn't match (a modified ROM?)"));
        }
        let tables = formats::ndt(&rom);
        match update_bytes(&game.ndt(), &tables) {
            Ok(wrote) => {
                s.tables += 1;
                if wrote {
                    s.tables_written += 1;
                }
                let streams = rom.streams.len();
                log(&format!(
                    "{shown}: {} ({}), {} files{}{}",
                    rom.header.title,
                    rom.header.game_code_text(),
                    rom.fat.len(),
                    if streams > 0 { format!(", {streams} video streams") } else { String::new() },
                    if wrote { "" } else { ", tables up to date" }
                ));
            }
            Err(e) => {
                log(&format!("skip {shown}: {}", reason(e)));
                s.failed += 1;
                continue;
            }
        }
        if let (true, Some(rom_slot)) = (core.takes_game_files(), core.rom_slot) {
            // data_path stays empty and the folder goes in front of each name:
            // the Pocket also applies data_path to the save's name, which must
            // stay Saves/<platform>/common/<game>.sav (as picking the .nds
            // directly gives; openfpga-PlayStation's shared cards work the same way).
            let folder = rel(&game.folder, &common);
            let prefix = if folder == "." { String::new() } else { format!("{folder}/") };
            let mut slots = vec![(rom_slot, format!("{prefix}{}", name_of(&rom_path)))];
            if let Some(t) = core.tables_slot {
                slots.push((t, format!("{prefix}{}", name_of(&game.ndt()))));
            }
            if let Some(v) = core.save_slot {
                slots.push((v, format!("{}.sav", game.name)));
            }
            let json = out.join(format!("{}.json", game.name));
            match update_bytes(&json, instance_json("", &slots).as_bytes()) {
                Ok(_) => s.instances += 1,
                Err(e) => {
                    log(&format!("  could not write {}.json: {}", game.name, reason(e)));
                    s.failed += 1;
                }
            }
        }
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_text() {
        let j = instance_json("", &[(1, "Pokémon \"P\".nds".into()), (5, "a.ndt".into())]);
        let v: serde_json::Value = serde_json::from_str(&j).unwrap();
        assert_eq!(v["instance"]["data_slots"][0]["filename"], "Pokémon \"P\".nds");
        assert_eq!(v["instance"]["data_slots"][1]["id"], 5);
        assert!(j.contains("Pok\\u00e9mon"));
    }

    #[test]
    fn slot_ids() {
        assert_eq!(slot_id(&serde_json::json!(5)), Some(5));
        assert_eq!(slot_id(&serde_json::json!("0x20")), Some(32));
        assert_eq!(slot_id(&serde_json::json!("7")), Some(7));
    }
}
