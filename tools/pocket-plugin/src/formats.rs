// SPDX-License-Identifier: GPL-3.0-or-later
// The two files the plugin makes for a game (docs/pocket-plugin.md):
//   .ndt  ROM tables: the ROM cache's read-ahead table, built from the
//         NitroFS file table, and the header's boot fields.
//   .ndz  a compressed ROM: 4 KiB blocks, each compressed on its own (LZ4)
//         with an index, so any block can be read at random.
// All fields are little-endian 32-bit words.

use crate::lz4;
use crate::rom::{self, Rom, BLOCK, BLOCK_SHIFT};
use std::io::{self, Read, Write};

pub const NDT_MAGIC: &[u8; 4] = b"NDT1";
pub const NDT_VERSION: u32 = 1;
/// The table starts here; the header words before it.
pub const NDT_TABLE_OFFSET: u32 = 0x1000;
pub const NDT_CAPPED: u32 = 1;

pub const NDZ_MAGIC: &[u8; 4] = b"NDZ1";
pub const NDZ_VERSION: u32 = 1;
pub const NDZ_HEADER: u32 = 0x40;
pub const CODEC_LZ4: u32 = 1;

fn words(out: &mut Vec<u8>, w: &[u32]) {
    for v in w {
        out.extend_from_slice(&v.to_le_bytes());
    }
}

fn word(b: &[u8], at: usize) -> u32 { u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) }

/// The .ndt file for a ROM.
pub fn ndt(rom: &Rom) -> Vec<u8> {
    let t = rom.table();
    let h = &rom.header;
    let streams = rom.stream_spans();
    let blocks = rom.blocks() as u32;
    let streams_at = NDT_TABLE_OFFSET + 4 * blocks;
    let size = streams_at + 8 * streams.len() as u32;
    let mut out = NDT_MAGIC.to_vec();
    words(&mut out, &[
        NDT_VERSION,                                     // 0x04
        size,                                            // 0x08 this file's size
        rom.size as u32,                                 // 0x0C ROM size
        BLOCK_SHIFT,                                     // 0x10
        blocks,                                          // 0x14
        NDT_TABLE_OFFSET,                                // 0x18
        if t.capped { NDT_CAPPED } else { 0 },           // 0x1C flags
        h.game_code,                                     // 0x20
        h.header_crc16 as u32 | (h.rom_version as u32) << 16, // 0x24
        streams_at,                                      // 0x28
        streams.len() as u32,                            // 0x2C
        h.arm9.rom_offset, h.arm9.entry, h.arm9.ram_address, h.arm9.size, // 0x30
        h.arm7.rom_offset, h.arm7.entry, h.arm7.ram_address, h.arm7.size, // 0x40
        h.fnt_offset, h.fnt_size, h.fat_offset, h.fat_size, // 0x50
        rom.fat.len() as u32,                            // 0x60 FAT entries read
        t.spans,                                         // 0x64
        t.marks,                                         // 0x68
        rom::save_type_word(h.game_code),                // 0x6C save type: {[31] valid, [2:0] melonDS SaveMemType}, melonDS's game list
    ]);
    out.resize(NDT_TABLE_OFFSET as usize, 0);
    words(&mut out, &t.words);
    for (s, e) in streams {
        words(&mut out, &[s, e]);
    }
    out
}

/// Header fields of a .ndt (for checks and tests).
pub struct NdtInfo {
    pub rom_size: u32,
    pub game_code: u32,
    pub header_crc16: u16,
    pub table: Vec<u32>,
}

pub fn read_ndt(b: &[u8]) -> Option<NdtInfo> {
    if b.len() < NDT_TABLE_OFFSET as usize || &b[..4] != NDT_MAGIC || word(b, 4) != NDT_VERSION || word(b, 8) as usize != b.len() {
        return None;
    }
    let (at, n) = (word(b, 0x18) as usize, word(b, 0x14) as usize);
    let table = b.get(at..at + 4 * n)?.chunks_exact(4).map(|c| word(c, 0)).collect();
    Some(NdtInfo { rom_size: word(b, 0x0C), game_code: word(b, 0x20), header_crc16: word(b, 0x24) as u16, table })
}

/// CRC-32 (IEEE), for the .ndz header.
pub fn crc32(mut crc: u32, data: &[u8]) -> u32 {
    crc = !crc;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

fn round4(n: usize) -> usize { (n + 3) & !3 }

/// Bytes block b of a ROM of rom_size holds.
pub fn block_len(rom_size: u64, b: u64) -> usize { (rom_size - (b << BLOCK_SHIFT)).min(BLOCK) as usize }

/// A compressed block as stored: LZ4 padded to 4 bytes, or the raw block
/// (padded) when that is no smaller.
pub fn pack_block(raw: &[u8]) -> Vec<u8> {
    let mut c = lz4::compress(raw);
    if round4(c.len()) >= round4(raw.len()) {
        c = raw.to_vec();
    }
    c.resize(round4(c.len()), 0);
    c
}

pub fn unpack_block(stored: &[u8], raw_len: usize) -> Result<Vec<u8>, String> {
    if stored.len() >= round4(raw_len) {
        return Ok(stored[..raw_len].to_vec());
    }
    lz4::decompress(stored, raw_len).map_err(|e| format!("{e:?}"))
}

/// Bytes the index and header take for a ROM.
pub fn ndz_overhead(rom_size: u64) -> u64 { NDZ_HEADER as u64 + 4 * (((rom_size + BLOCK - 1) >> BLOCK_SHIFT) + 1) }

/// Compress src (rom_size bytes) into out as a .ndz. The index comes first,
/// so the blocks are compressed into memory one megabyte at a time and the
/// index is known before anything is written: the blocks are written as a
/// second pass (compress is called twice per block, see compress_ndz).
pub struct NdzPlan {
    pub rom_size: u64,
    pub crc: u32,
    pub game_code: u32,
    /// Stored length of every block.
    pub lens: Vec<u32>,
}

impl NdzPlan {
    pub fn file_size(&self) -> u64 { ndz_overhead(self.rom_size) + self.lens.iter().map(|&l| l as u64).sum::<u64>() }

    pub fn header_and_index(&self) -> Vec<u8> {
        let blocks = self.lens.len() as u32;
        let mut out = NDZ_MAGIC.to_vec();
        let index_at = NDZ_HEADER;
        let data_at = index_at + 4 * (blocks + 1);
        words(&mut out, &[NDZ_VERSION, self.rom_size as u32, BLOCK_SHIFT, blocks, index_at, data_at, CODEC_LZ4, self.crc, self.game_code]);
        out.resize(NDZ_HEADER as usize, 0);
        let mut at = data_at;
        for &l in &self.lens {
            words(&mut out, &[at]);
            at += l;
        }
        words(&mut out, &[at]);
        out
    }
}

/// First pass: the stored length of every block and the ROM's CRC-32.
pub fn plan_ndz(src: &mut dyn Read, rom_size: u64, progress: &mut dyn FnMut(u64)) -> io::Result<NdzPlan> {
    let mut lens = vec![];
    let mut crc = 0;
    let mut game_code = 0;
    each_block(src, rom_size, &mut |b, raw| {
        if b == 0 && raw.len() >= 0x10 {
            game_code = word(raw, 0x0C);
        }
        crc = crc32(crc, raw);
        lens.push(pack_block(raw).len() as u32);
        if b % 256 == 255 {
            progress((b + 1) << BLOCK_SHIFT);
        }
        Ok(())
    })?;
    Ok(NdzPlan { rom_size, crc, game_code, lens })
}

/// Second pass: write the .ndz (the blocks must match the plan).
pub fn write_ndz(src: &mut dyn Read, plan: &NdzPlan, out: &mut dyn Write, progress: &mut dyn FnMut(u64)) -> io::Result<()> {
    out.write_all(&plan.header_and_index())?;
    each_block(src, plan.rom_size, &mut |b, raw| {
        let stored = pack_block(raw);
        if stored.len() as u32 != plan.lens[b as usize] {
            return Err(io::Error::other("the ROM changed while it was being compressed"));
        }
        if b % 256 == 255 {
            progress((b + 1) << BLOCK_SHIFT);
        }
        out.write_all(&stored)
    })
}

fn each_block(src: &mut dyn Read, rom_size: u64, f: &mut dyn FnMut(u64, &[u8]) -> io::Result<()>) -> io::Result<()> {
    let blocks = (rom_size + BLOCK - 1) >> BLOCK_SHIFT;
    let mut buf = vec![0u8; BLOCK as usize];
    for b in 0..blocks {
        let n = block_len(rom_size, b);
        src.read_exact(&mut buf[..n])?;
        f(b, &buf[..n])?;
    }
    Ok(())
}

/// A .ndz's header fields.
pub struct NdzInfo {
    pub rom_size: u64,
    pub blocks: u64,
    pub crc: u32,
    pub game_code: u32,
    pub index: Vec<u32>,
}

pub fn read_ndz_header(src: &mut dyn Read) -> io::Result<NdzInfo> {
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, format!("not a .ndz file ({what})"));
    let mut h = [0u8; NDZ_HEADER as usize];
    src.read_exact(&mut h)?;
    if &h[..4] != NDZ_MAGIC || word(&h, 4) != NDZ_VERSION || word(&h, 0x0C) != BLOCK_SHIFT || word(&h, 0x1C) != CODEC_LZ4 {
        return Err(bad("magic, version, block size or codec"));
    }
    let (rom_size, blocks) = (word(&h, 8) as u64, word(&h, 0x10) as u64);
    if blocks != (rom_size + BLOCK - 1) >> BLOCK_SHIFT || word(&h, 0x14) != NDZ_HEADER {
        return Err(bad("block count"));
    }
    let mut raw = vec![0u8; 4 * (blocks as usize + 1)];
    src.read_exact(&mut raw)?;
    let index: Vec<u32> = raw.chunks_exact(4).map(|c| word(c, 0)).collect();
    if index[0] != word(&h, 0x18) || index.windows(2).any(|w| w[1] < w[0] || (w[1] - w[0]) % 4 != 0) {
        return Err(bad("index"));
    }
    Ok(NdzInfo { rom_size, blocks, crc: word(&h, 0x20), game_code: word(&h, 0x24), index })
}

/// Decompress a whole .ndz (read in order) into out; checks the CRC-32.
pub fn decompress_ndz(src: &mut dyn Read, out: &mut dyn Write) -> io::Result<NdzInfo> {
    let info = read_ndz_header(src)?;
    let mut crc = 0;
    let mut stored = vec![];
    for b in 0..info.blocks {
        let len = (info.index[b as usize + 1] - info.index[b as usize]) as usize;
        stored.resize(len, 0);
        src.read_exact(&mut stored)?;
        let raw = unpack_block(&stored, block_len(info.rom_size, b))
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("block {b}: {e}")))?;
        crc = crc32(crc, &raw);
        out.write_all(&raw)?;
    }
    if crc != info.crc {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "CRC-32 differs from the original's"));
    }
    Ok(info)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom::{self, tests::make_rom};
    use std::io::Cursor;

    fn ndz_of(data: &[u8]) -> Vec<u8> {
        let plan = plan_ndz(&mut Cursor::new(data), data.len() as u64, &mut |_| {}).unwrap();
        let mut out = vec![];
        write_ndz(&mut Cursor::new(data), &plan, &mut out, &mut |_| {}).unwrap();
        assert_eq!(out.len() as u64, plan.file_size());
        out
    }

    #[test]
    fn ndz_round_trip() {
        let mut seed = 99u32;
        for size in [0usize, 1, 4095, 4096, 4097, 3 * 4096 + 5, 40000] {
            let data: Vec<u8> = (0..size)
                .map(|i| {
                    seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
                    if i % 8192 < 4096 { (i / 64) as u8 } else { (seed >> 16) as u8 }
                })
                .collect();
            let z = ndz_of(&data);
            let mut back = vec![];
            let info = decompress_ndz(&mut Cursor::new(&z), &mut back).unwrap();
            assert_eq!(back, data, "size {size}");
            assert_eq!(info.rom_size, size as u64);
            // random access through the index
            for b in 0..info.blocks {
                let (s, e) = (info.index[b as usize] as usize, info.index[b as usize + 1] as usize);
                let raw = unpack_block(&z[s..e], block_len(size as u64, b)).unwrap();
                assert_eq!(raw, &data[(b as usize) * 4096..((b as usize) * 4096 + raw.len())]);
            }
            if size == 40000 {
                assert!(z.len() < size * 3 / 4, "compressible half should shrink: {}", z.len());
            }
        }
    }

    #[test]
    fn ndz_raw_blocks_and_crc() {
        let mut seed = 7u64;
        let data: Vec<u8> = (0..8192).map(|_| { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1); (seed >> 33) as u8 }).collect();
        let z = ndz_of(&data);
        let info = read_ndz_header(&mut Cursor::new(&z)).unwrap();
        assert_eq!(info.index[1] - info.index[0], 4096, "random data is stored raw");
        let mut bad = z.clone();
        let last = bad.len() - 1;
        bad[last] ^= 1;
        assert!(decompress_ndz(&mut Cursor::new(&bad), &mut vec![]).is_err());
    }

    #[test]
    fn crc32_known() {
        assert_eq!(crc32(0, b"123456789"), 0xCBF43926);
        assert_eq!(crc32(crc32(0, b"1234"), b"56789"), 0xCBF43926);
    }

    #[test]
    fn ndt_layout() {
        let r = make_rom(0x40000, &[("f", 0xB800, 0x11000), ("m.mods", 0x21000, 0x22001)]);
        let rom = rom::read(&mut Cursor::new(&r), r.len() as u64).unwrap();
        let b = ndt(&rom);
        assert_eq!(&b[..4], b"NDT1");
        assert_eq!(b.len(), 0x1000 + 4 * 0x40 + 8);
        let info = read_ndt(&b).unwrap();
        assert_eq!(info.table, rom.table().words);
        assert_eq!(info.rom_size, 0x40000);
        assert_eq!(&info.game_code.to_le_bytes(), b"ATST");
        assert_eq!(word(&b, 0x30), 0x4000);
        assert_eq!(word(&b, 0x2C), 1);
        assert_eq!((word(&b, 0x1100), word(&b, 0x1104)), (0x21000, 0x22001));
    }
}
