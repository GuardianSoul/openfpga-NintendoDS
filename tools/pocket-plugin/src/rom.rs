// SPDX-License-Identifier: GPL-3.0-or-later
// What the plugin reads from a .nds ROM: the header fields the core's boot
// and ROM cache use, the NitroFS file table (FAT) and the file names (FNT).
//
// The read-ahead table is built with the same rule, in the same order, as
// the core's own scan in rtl/pocket/nds_cart_cache.sv (and
// tools/mem-replay/cart_sim.py), so a core that loads it can skip that scan
// and get the same table (docs/pocket-plugin.md).

use std::io::{self, Read, Seek, SeekFrom};

pub const BLOCK_SHIFT: u32 = 12;
pub const BLOCK: u64 = 1 << BLOCK_SHIFT;
/// Most read-ahead blocks one miss fetches (the cache's 16 KiB).
pub const MAX_AHEAD: u32 = 4;
/// Table word bits.
pub const AHEAD_SHIFT: u32 = 29;
pub const STREAM_BIT: u32 = 1 << 28;
/// File name endings of streamed video (Mobiclip, Actimagine VX).
pub const STREAM_EXTS: [&str; 2] = [".mods", ".vx"];

fn u32_at(b: &[u8], at: usize) -> u32 { u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) }
fn u16_at(b: &[u8], at: usize) -> u16 { u16::from_le_bytes(b[at..at + 2].try_into().unwrap()) }

/// One CPU's binary as the header describes it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Binary {
    pub rom_offset: u32,
    pub entry: u32,
    pub ram_address: u32,
    pub size: u32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Header {
    pub title: String,
    pub game_code: u32,
    pub rom_version: u8,
    pub arm9: Binary,
    pub arm7: Binary,
    pub fnt_offset: u32,
    pub fnt_size: u32,
    pub fat_offset: u32,
    pub fat_size: u32,
    pub header_crc16: u16,
    /// The CRC-16 of 0x000..0x15D matches header_crc16.
    pub crc_ok: bool,
}

pub fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= b as u16;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xA001 } else { crc >> 1 };
        }
    }
    crc
}

pub fn parse_header(h: &[u8]) -> Option<Header> {
    if h.len() < 0x200 {
        return None;
    }
    let bin = |at: usize| Binary { rom_offset: u32_at(h, at), entry: u32_at(h, at + 4), ram_address: u32_at(h, at + 8), size: u32_at(h, at + 12) };
    let title: String = h[..12].iter().take_while(|&&c| c != 0).map(|&c| if (0x20..0x7f).contains(&c) { c as char } else { '?' }).collect();
    let header_crc16 = u16_at(h, 0x15E);
    Some(Header {
        title,
        game_code: u32_at(h, 0x0C),
        rom_version: h[0x1E],
        arm9: bin(0x20),
        arm7: bin(0x30),
        fnt_offset: u32_at(h, 0x40),
        fnt_size: u32_at(h, 0x44),
        fat_offset: u32_at(h, 0x48),
        fat_size: u32_at(h, 0x4C),
        header_crc16,
        crc_ok: crc16(&h[..0x15E]) == header_crc16,
    })
}

impl Header {
    pub fn game_code_text(&self) -> String {
        self.game_code.to_le_bytes().iter().map(|&c| if (0x20..0x7f).contains(&c) { c as char } else { '?' }).collect()
    }
}

/// Everything the sidecar is made from.
pub struct Rom {
    pub size: u64,
    pub header: Header,
    /// FAT entries (start, end) as stored, the ones the cache reads (clipped
    /// to the ROM like the cache does).
    pub fat: Vec<(u32, u32)>,
    /// File IDs whose names end in a STREAM_EXTS ending.
    pub streams: Vec<u16>,
}

/// Read bytes at offset; short at the end of the file.
fn read_at<R: Read + Seek>(f: &mut R, offset: u64, len: usize) -> io::Result<Vec<u8>> {
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::with_capacity(len);
    f.take(len as u64).read_to_end(&mut buf)?;
    Ok(buf)
}

/// FAT entries the cache scans: min(fat_size, rom - fat_offset) / 8 of them.
fn fat_entries(size: u64, h: &Header) -> u64 {
    let off = h.fat_offset as u64;
    if off >= size { 0 } else { (h.fat_size as u64).min(size - off) / 8 }
}

pub fn read<R: Read + Seek>(f: &mut R, size: u64) -> io::Result<Rom> {
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_string());
    let header = parse_header(&read_at(f, 0, 0x200)?).ok_or_else(|| bad("shorter than a DS header"))?;
    let n = fat_entries(size, &header);
    let raw = read_at(f, header.fat_offset as u64, (n * 8) as usize)?;
    let fat = raw.chunks_exact(8).map(|e| (u32_at(e, 0), u32_at(e, 4))).collect::<Vec<_>>();
    let streams = if header.fnt_offset as u64 >= size || header.fnt_size == 0 {
        vec![]
    } else {
        let fnt = read_at(f, header.fnt_offset as u64, header.fnt_size.min(16 << 20) as usize)?;
        file_names(&fnt).into_iter().filter(|(_, name)| is_stream(name)).map(|(id, _)| id).collect()
    };
    Ok(Rom { size, header, fat, streams })
}

pub fn is_stream(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    STREAM_EXTS.iter().any(|e| lower.ends_with(e))
}

/// (file ID, path) of every named file in a NitroFS name table. Malformed
/// tables give what could be read.
pub fn file_names(fnt: &[u8]) -> Vec<(u16, String)> {
    let mut out = vec![];
    if fnt.len() < 8 {
        return out;
    }
    let dirs = (u16_at(fnt, 6) as usize).clamp(1, 4096).min(fnt.len() / 8);
    let mut stack = vec![(0usize, String::new())];
    let mut seen = vec![false; dirs];
    while let Some((d, path)) = stack.pop() {
        if d >= dirs || seen[d] {
            continue;
        }
        seen[d] = true;
        let mut at = u32_at(fnt, d * 8) as usize;
        let mut id = u16_at(fnt, d * 8 + 4);
        while at < fnt.len() {
            let len = fnt[at];
            at += 1;
            if len == 0 || len == 0x80 {
                break;
            }
            let n = (len & 0x7f) as usize;
            if at + n > fnt.len() {
                break;
            }
            let name = String::from_utf8_lossy(&fnt[at..at + n]).into_owned();
            at += n;
            let full = if path.is_empty() { name } else { format!("{path}/{name}") };
            if len & 0x80 != 0 {
                if at + 2 > fnt.len() {
                    break;
                }
                let sub = u16_at(fnt, at) as usize;
                at += 2;
                stack.push((sub.wrapping_sub(0xF000), full));
            } else {
                out.push((id, full));
                id = id.wrapping_add(1);
            }
        }
    }
    out.sort();
    out
}

fn ceil_blk(x: u32) -> u64 { (x as u64 + BLOCK - 1) >> BLOCK_SHIFT }

/// The cache's read-ahead table: one word per 4 KiB block.
pub struct Table {
    pub words: Vec<u32>,
    /// Spans that marked at least one block, and block writes (the RTL's
    /// st_spans and st_marks).
    pub spans: u32,
    pub marks: u32,
    /// The scan stopped at 4 x blocks writes, as the RTL's init_capped.
    pub capped: bool,
}

impl Rom {
    pub fn blocks(&self) -> u64 { (self.size + BLOCK - 1) >> BLOCK_SHIFT }

    /// Spans in the order the cache marks them: ARM9, ARM7, every FAT entry.
    /// Ends wrap at 32 bits as in the RTL.
    pub fn spans(&self) -> Vec<(u32, u32)> {
        let h = &self.header;
        let mut s = vec![
            (h.arm9.rom_offset, h.arm9.rom_offset.wrapping_add(h.arm9.size)),
            (h.arm7.rom_offset, h.arm7.rom_offset.wrapping_add(h.arm7.size)),
        ];
        s.extend(&self.fat);
        s
    }

    /// The table nds_cart_cache.sv builds at start, plus the stream bit.
    pub fn table(&self) -> Table {
        let n = self.blocks();
        let rom = self.size.min(u32::MAX as u64) as u32;
        let mut t = Table { words: vec![0; n as usize], spans: 0, marks: 0, capped: false };
        let mut budget = n * 4;
        'spans: for (s, e) in self.spans() {
            let end = e.min(rom);
            if s >= end {
                continue;
            }
            let (sb, se) = (ceil_blk(s), ceil_blk(end));
            t.spans += 1;
            for b in sb..se {
                if budget == 0 {
                    t.capped = true;
                    break 'spans;
                }
                let room = (se - 1 - b).min(MAX_AHEAD as u64) as u32;
                // byte-3 write: the stream bit (bit 28) is set below, after the scan
                t.words[b as usize] = room << AHEAD_SHIFT;
                budget -= 1;
                t.marks += 1;
            }
        }
        for &id in &self.streams {
            let Some(&(s, e)) = self.fat.get(id as usize) else { continue };
            let end = e.min(rom);
            for b in (s as u64 >> BLOCK_SHIFT)..ceil_blk(end).min(n) {
                t.words[b as usize] |= STREAM_BIT;
            }
        }
        t
    }

    /// Stream files as (start, end) ROM byte spans.
    pub fn stream_spans(&self) -> Vec<(u32, u32)> {
        self.streams.iter().filter_map(|&id| self.fat.get(id as usize).copied()).collect()
    }
}

/// The .ndt save-type word for a game code, from melonDS's game list:
/// [31] valid, [2:0] melonDS SaveMemType (0 none, 1-4 EEPROM 512 B / 8 /
/// 64 / 128 KiB, 5-7 FLASH 256 KiB / 512 KiB / 1 MiB). 0 when the game is
/// not listed, or has a NAND save (types 8-10) or an unknown one.
pub fn save_type_word(game_code: u32) -> u32 {
    match crate::romlist::ROMLIST.binary_search_by_key(&game_code, |e| e.0) {
        Ok(i) if crate::romlist::ROMLIST[i].1 <= 7 => 1 << 31 | crate::romlist::ROMLIST[i].1 as u32,
        _ => 0,
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::io::Cursor;

    /// A small ROM: header, FNT with one folder, FAT with the given files.
    pub fn make_rom(size: usize, files: &[(&str, u32, u32)]) -> Vec<u8> {
        let mut r = vec![0u8; size];
        r[..4].copy_from_slice(b"TEST");
        r[0x0C..0x10].copy_from_slice(b"ATST");
        let put = |r: &mut Vec<u8>, at: usize, v: u32| r[at..at + 4].copy_from_slice(&v.to_le_bytes());
        // ARM9 0x4000+0x2100, ARM7 0x8000+0x800
        put(&mut r, 0x20, 0x4000);
        put(&mut r, 0x24, 0x0200_0800);
        put(&mut r, 0x28, 0x0200_0000);
        put(&mut r, 0x2C, 0x2100);
        put(&mut r, 0x30, 0x8000);
        put(&mut r, 0x34, 0x0238_0000);
        put(&mut r, 0x38, 0x0238_0000);
        put(&mut r, 0x3C, 0x800);
        // FNT at 0x9000: root (dir 0) with "data" (dir 1) holding the files
        let mut fnt = vec![];
        fnt.extend(16u32.to_le_bytes());
        fnt.extend(0u16.to_le_bytes());
        fnt.extend(2u16.to_le_bytes());
        let sub1_at = fnt.len() + 8;
        fnt.extend(0u32.to_le_bytes()); // patched below
        fnt.extend(0u16.to_le_bytes());
        fnt.extend(0xF000u16.to_le_bytes());
        // root sub-table
        fnt.push(0x80 | 4);
        fnt.extend(b"data");
        fnt.extend(0xF001u16.to_le_bytes());
        fnt.push(0);
        let sub1 = fnt.len() as u32;
        fnt[sub1_at - 8..sub1_at - 4].copy_from_slice(&sub1.to_le_bytes());
        for (name, _, _) in files {
            fnt.push(name.len() as u8);
            fnt.extend(name.as_bytes());
        }
        fnt.push(0);
        r[0x9000..0x9000 + fnt.len()].copy_from_slice(&fnt);
        put(&mut r, 0x40, 0x9000);
        put(&mut r, 0x44, fnt.len() as u32);
        put(&mut r, 0x48, 0xA000);
        put(&mut r, 0x4C, files.len() as u32 * 8);
        for (i, (_, s, e)) in files.iter().enumerate() {
            put(&mut r, 0xA000 + 8 * i, *s);
            put(&mut r, 0xA004 + 8 * i, *e);
        }
        let crc = crc16(&r[..0x15E]);
        r[0x15E..0x160].copy_from_slice(&crc.to_le_bytes());
        r
    }

    fn rom(r: &[u8]) -> Rom { read(&mut Cursor::new(r), r.len() as u64).unwrap() }

    #[test]
    fn header_fields() {
        let r = make_rom(0x40000, &[("a.bin", 0xB000, 0xB010)]);
        let rom = rom(&r);
        assert!(rom.header.crc_ok);
        assert_eq!(rom.header.game_code_text(), "ATST");
        assert_eq!(rom.header.arm9, Binary { rom_offset: 0x4000, entry: 0x0200_0800, ram_address: 0x0200_0000, size: 0x2100 });
        assert_eq!(rom.fat, vec![(0xB000, 0xB010)]);
    }

    #[test]
    fn names_and_streams() {
        let r = make_rom(0x40000, &[("a.bin", 0xB000, 0xB010), ("movie.MODS", 0x10000, 0x30000), ("b.vx", 0x30000, 0x30001)]);
        let fnt = &r[0x9000..0x9100];
        let names = file_names(fnt);
        assert_eq!(names, vec![(0, "data/a.bin".into()), (1, "data/movie.MODS".into()), (2, "data/b.vx".into())]);
        assert_eq!(rom(&r).streams, vec![1, 2]);
    }

    #[test]
    fn table_rule() {
        // ARM9 0x4000..0x6100: blocks 4,5,6 -> 2,1,0. ARM7 0x8000..0x8800: block 8 -> 0.
        // file 0xB800..0x11000: blocks 12..16 (first byte inside) -> 4,3,2,1,0
        // file 0x20000..0x20000: empty, nothing. file past the end: clipped.
        let r = make_rom(0x40000, &[("f", 0xB800, 0x11000), ("e", 0x20000, 0x20000), ("g", 0x3F000, 0x50000), ("m.mods", 0x21000, 0x22001)]);
        let t = rom(&r).table();
        let ra = |b: usize| t.words[b] >> AHEAD_SHIFT;
        assert_eq!((ra(4), ra(5), ra(6), ra(7), ra(8)), (2, 1, 0, 0, 0));
        assert_eq!((11..17).map(ra).collect::<Vec<_>>(), vec![0, 4, 3, 2, 1, 0]);
        assert_eq!(ra(0x3F), 0);
        assert_eq!(t.words.len(), 0x40);
        // stream: blocks 0x21, 0x22 (the byte at 0x22000); 0x23 not
        assert_eq!(t.words[0x21] & STREAM_BIT, STREAM_BIT);
        assert_eq!(t.words[0x22], STREAM_BIT);
        assert_eq!(t.words[0x23], 0);
        // spans: ARM9, ARM7, f, g, m; marks 3 + 1 + 5 + 1 + 2
        assert_eq!((t.spans, t.marks, t.capped), (5, 12, false));
    }

    #[test]
    fn table_cap() {
        // 1000 copies of the whole ROM: the scan stops after 4 x blocks writes
        let files: Vec<(&str, u32, u32)> = (0..1000).map(|_| ("x", 0u32, 0x8000u32)).collect();
        let r = make_rom(0x10000, &files[..]);
        let rom = rom(&r);
        assert_eq!(rom.fat.len(), 1000);
        let t = rom.table();
        assert!(t.capped);
        assert_eq!(t.marks as u64, 4 * rom.blocks());
    }

    #[test]
    fn save_types() {
        let code = |c: &[u8; 4]| u32::from_le_bytes(*c);
        let valid = 1u32 << 31;
        assert_eq!(save_type_word(code(b"IPKE")), valid | 6, "HeartGold (USA): FLASH 512 KiB");
        assert_eq!(save_type_word(code(b"CPUE")), valid | 6, "Platinum (USA): FLASH 512 KiB");
        assert_eq!(save_type_word(code(b"A2DE")), valid | 2, "NSMB (USA): EEPROM 8 KiB");
        assert_eq!(save_type_word(code(b"YKGP")), valid | 3, "KH 358/2 Days (Europe): EEPROM 64 KiB");
        assert_eq!(save_type_word(code(b"AMCE")), valid | 5, "Mario Kart DS (USA): FLASH 256 KiB");
        assert_eq!(save_type_word(code(b"ATST")), 0, "not listed");
        // NAND (WarioWare D.I.Y., melonDS type 8) is left to the core
        let nand = crate::romlist::ROMLIST.iter().find(|e| e.1 == 8).unwrap().0;
        assert_eq!(save_type_word(nand), 0);
        let none = crate::romlist::ROMLIST.iter().find(|e| e.1 == 0).unwrap().0;
        assert_eq!(save_type_word(none), valid, "listed with no save");
        assert!(crate::romlist::ROMLIST.windows(2).all(|w| w[0].0 < w[1].0));
    }

    #[test]
    fn crc16_known() {
        assert_eq!(crc16(b"123456789"), 0x4B37); // CRC-16/MODBUS
    }
}
