// SPDX-License-Identifier: GPL-3.0-or-later
// Safe writes to the SD card, as openfpga-PlayStation's plugin does them
// (tools/pocket-plugin/src/instances.rs and convert.rs there):
// - a large file first claims its size plus RESERVE (FAT and exFAT have no
//   sparse files, so the claim fails with nothing written on a full card);
// - a file is written as <name>.part, synced and read back, and only then
//   gets its real name;
// - originals are removed only after that;
// - a stopped run leaves only .part files, which the next run removes.

use std::fs;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// Space a large write always leaves free on the SD card.
pub const RESERVE: u64 = 256 << 20;
pub const SPACE_CHECK: &str = ".ds-space-check";
pub const NO_SPACE: &str = "not enough free space";

pub fn name_of(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The name without its last suffix.
pub fn stem(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) if i > 0 => &name[..i],
        _ => name,
    }
}

pub fn has_ext(name: &str, ext: &str) -> bool {
    name.len() > ext.len() && name[name.len() - ext.len()..].eq_ignore_ascii_case(ext)
}

/// path below base, '/'-separated ('.' for base itself).
pub fn rel(path: &Path, base: &Path) -> String {
    let parts: Vec<String> = path.strip_prefix(base).unwrap_or(path).components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    if parts.is_empty() { ".".into() } else { parts.join("/") }
}

pub fn size(path: &Path) -> Option<u64> { fs::metadata(path).ok().filter(|m| m.is_file()).map(|m| m.len()) }

pub fn mb(bytes: u64) -> u64 { (bytes + (1 << 20) - 1) >> 20 }

/// Files under folder whose name passes test, sorted, without macOS '._' files.
pub fn walk(folder: &Path, test: &dyn Fn(&str) -> bool) -> Vec<PathBuf> {
    fn visit(dir: &Path, test: &dyn Fn(&str) -> bool, found: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = name_of(&path);
            match entry.file_type() {
                Ok(t) if t.is_dir() => visit(&path, test, found),
                Ok(t) if t.is_file() && test(&name) && !name.starts_with("._") => found.push(path),
                _ => {}
            }
        }
    }
    let mut found = vec![];
    visit(folder, test, &mut found);
    found.sort();
    found
}

pub fn no_space(needed: u64) -> io::Error {
    io::Error::new(io::ErrorKind::StorageFull, format!("{NO_SPACE} (needs {} MB plus {} MB to spare)", mb(needed), mb(RESERVE)))
}

/// io errors as report text; running out of space always starts with NO_SPACE.
pub fn reason(e: io::Error) -> String {
    if e.kind() == io::ErrorKind::StorageFull && !e.to_string().starts_with(NO_SPACE) {
        format!("{NO_SPACE} ({e})")
    } else {
        e.to_string()
    }
}

/// Tests set test_card_bytes in the plugin config to make the SD card that
/// small (hosts never set it): a claim fails when the card's files, the claim
/// and RESERVE would not fit.
fn card_too_small_for(path: &Path, bytes: u64) -> bool {
    let card = Path::new(crate::CARD);
    if !path.starts_with(card) {
        return false;
    }
    let Some(limit) = crate::config("test_card_bytes").and_then(|v| v.parse::<u64>().ok()) else { return false };
    let used: u64 = walk(card, &|_| true).iter().filter_map(|p| size(p)).sum();
    used + bytes + RESERVE > limit
}

/// Claim bytes plus RESERVE for file.
pub fn claim(file: &fs::File, path: &Path, bytes: u64) -> io::Result<()> {
    if card_too_small_for(path, bytes) {
        return Err(no_space(bytes));
    }
    file.set_len(bytes + RESERVE).map_err(|_| no_space(bytes))
}

/// Whether bytes plus RESERVE fit on the card now (claimed, then let go).
pub fn has_room(card: &Path, bytes: u64) -> bool {
    let check = card.join(SPACE_CHECK);
    let ok = fs::File::create(&check).and_then(|f| claim(&f, &check, bytes)).is_ok();
    let _ = fs::remove_file(&check);
    ok
}

/// FNV-1a over everything written or read back.
struct Hashing<'a> {
    inner: &'a mut fs::File,
    hash: u64,
    len: u64,
}

impl Write for Hashing<'_> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(data)?;
        self.hash = fnv(self.hash, &data[..n]);
        self.len += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> { self.inner.flush() }
}

fn fnv(mut hash: u64, data: &[u8]) -> u64 {
    for &b in data {
        hash = (hash ^ b as u64).wrapping_mul(0x100000001b3);
    }
    hash
}
const FNV: u64 = 0xcbf29ce484222325;

pub fn part_of(path: &Path) -> PathBuf { path.with_file_name(format!("{}.part", name_of(path))) }

/// Write path via path.part, so a stopped run never leaves a short file
/// under the real name. With reserve, the part file first claims that many
/// bytes plus RESERVE. The file is synced and read back (and given to check,
/// when there is one, from its start) before it is renamed.
pub fn write_checked(
    path: &Path,
    reserve: Option<u64>,
    parts: &mut dyn FnMut(&mut dyn Write) -> io::Result<()>,
    check: Option<&mut dyn FnMut(&mut fs::File) -> io::Result<()>>,
) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let partial = part_of(path);
    let result = (|| {
        let mut file = fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&partial)?;
        if let Some(n) = reserve {
            claim(&file, &partial, n)?;
        }
        let mut out = io::BufWriter::with_capacity(1 << 20, Hashing { inner: &mut file, hash: FNV, len: 0 });
        parts(&mut out)?;
        let out = out.into_inner().map_err(|e| e.into_error())?;
        let (hash, len) = (out.hash, out.len);
        file.set_len(len)?;
        file.sync_all()?;
        file.seek(SeekFrom::Start(0))?;
        let (mut sum, mut buffer) = (FNV, vec![0u8; 1 << 20]);
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            sum = fnv(sum, &buffer[..n]);
        }
        if sum != hash {
            return Err(io::Error::other(format!("{}: read back differently from what was written", name_of(path))));
        }
        if let Some(check) = check {
            file.seek(SeekFrom::Start(0))?;
            check(&mut file)?;
        }
        Ok(())
    })();
    match result {
        Ok(()) => fs::rename(&partial, path),
        Err(e) => {
            let _ = fs::remove_file(&partial);
            Err(e)
        }
    }
}

pub fn write_bytes(path: &Path, data: &[u8]) -> io::Result<()> { write_checked(path, None, &mut |out| out.write_all(data), None) }

/// Write data unless path already holds exactly that; returns whether it wrote.
pub fn update_bytes(path: &Path, data: &[u8]) -> io::Result<bool> {
    if fs::read(path).ok().as_deref() == Some(data) {
        return Ok(false);
    }
    write_bytes(path, data).map(|_| true)
}

/// Copy count bytes of src (from offset) to out.
pub fn copy_range(src: &Path, offset: u64, count: u64, out: &mut dyn Write) -> io::Result<()> {
    let mut file = fs::File::open(src)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut left = count;
    let mut buffer = vec![0u8; 1 << 22];
    while left > 0 {
        let want = left.min(buffer.len() as u64) as usize;
        let got = file.read(&mut buffer[..want])?;
        if got == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, format!("{}: short read", name_of(src))));
        }
        out.write_all(&buffer[..got])?;
        left -= got as u64;
    }
    Ok(())
}

/// Read until buf is full or the file ends.
pub fn fill(f: &mut dyn Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..])? {
            0 => break,
            k => n += k,
        }
    }
    Ok(n)
}

/// Whether two readers give the same bytes.
pub fn same_stream(a: &mut dyn Read, b: &mut dyn Read) -> io::Result<bool> {
    let (mut x, mut y) = (vec![0u8; 1 << 20], vec![0u8; 1 << 20]);
    loop {
        let (n, m) = (fill(a, &mut x)?, fill(b, &mut y)?);
        if n != m || x[..n] != y[..m] {
            return Ok(false);
        }
        if n == 0 {
            return Ok(true);
        }
    }
}

/// Whether two files hold the same bytes.
pub fn same_file(a: &Path, b: &Path) -> bool {
    if size(a).is_none() || size(a) != size(b) {
        return false;
    }
    let (Ok(mut a), Ok(mut b)) = (fs::File::open(a), fs::File::open(b)) else { return false };
    same_stream(&mut a, &mut b).unwrap_or(false)
}

/// Remove what a stopped run can leave behind: .part files of the plugin's
/// kinds under Assets/<platform> and the space check. Returns how many went.
pub fn clean_leftovers(card: &Path, platform: &str) -> usize {
    const OURS: [&str; 4] = [".ndz.part", ".ndt.part", ".json.part", ".nds.part"];
    let mut found = walk(&card.join("Assets").join(platform), &|n| OURS.iter().any(|e| n.ends_with(e)));
    let check = card.join(SPACE_CHECK);
    if check.is_file() {
        found.push(check);
    }
    found.iter().filter(|f| fs::remove_file(f).is_ok()).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ds-plugin-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn write_then_rename() {
        let d = temp("write");
        let p = d.join("a.ndt");
        write_bytes(&p, b"hello").unwrap();
        assert_eq!(fs::read(&p).unwrap(), b"hello");
        assert!(!part_of(&p).exists());
        assert!(!update_bytes(&p, b"hello").unwrap());
        assert!(update_bytes(&p, b"hellO").unwrap());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn failed_write_leaves_nothing() {
        let d = temp("fail");
        let p = d.join("a.ndz");
        fs::write(&p, b"old").unwrap();
        let r = write_checked(&p, None, &mut |out| { out.write_all(b"new")?; Err(io::Error::other("stopped")) }, None);
        assert!(r.is_err());
        assert_eq!(fs::read(&p).unwrap(), b"old");
        assert!(!part_of(&p).exists());
        // a failing check keeps the old file too
        let r = write_checked(&p, None, &mut |out| out.write_all(b"new"), Some(&mut |_f: &mut fs::File| Err(io::Error::other("bad"))));
        assert!(r.is_err());
        assert_eq!(fs::read(&p).unwrap(), b"old");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn claim_sizes_the_part_file() {
        let d = temp("claim");
        let p = d.join("big.ndz");
        let mut seen = 0;
        write_checked(&p, Some(1000), &mut |out| out.write_all(&[1, 2, 3]), Some(&mut |f: &mut fs::File| {
            seen = f.metadata()?.len();
            Ok(())
        }))
        .unwrap();
        assert_eq!(seen, 3, "trimmed to what was written before the check");
        assert_eq!(size(&p), Some(3));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn names() {
        assert_eq!(stem("Game (USA).nds"), "Game (USA)");
        assert!(has_ext("A.NDS", ".nds"));
        assert!(!has_ext(".nds", ".nds"));
    }
}
