// SPDX-License-Identifier: GPL-3.0-or-later
// LZ4 block format (https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
// for one block at a time, every block on its own (no dictionary).
//
// The compressor searches hash chains over the whole block, with one step
// of lazy matching (what lz4's HC levels do). Its output follows the
// format's end rules (the last 5 bytes are literals, no match starts in the
// last 12), so any LZ4 decoder reads it; the core's decoder only needs to
// stop once the block is full.

const MIN_MATCH: usize = 4;
const LAST_LITERALS: usize = 5;
const MF_LIMIT: usize = 12;
const HASH_BITS: u32 = 12;
const MAX_CHAIN: usize = 256;

fn hash(b: &[u8], i: usize) -> usize {
    let v = u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
    (v.wrapping_mul(2654435761) >> (32 - HASH_BITS)) as usize
}

fn push_len(out: &mut Vec<u8>, mut n: usize) {
    while n >= 255 {
        out.push(255);
        n -= 255;
    }
    out.push(n as u8);
}

fn sequence(out: &mut Vec<u8>, literals: &[u8], m: Option<(usize, usize)>) {
    let lit = literals.len();
    let ml = m.map_or(0, |(_, len)| len - MIN_MATCH);
    out.push(((lit.min(15) as u8) << 4) | ml.min(15) as u8);
    if lit >= 15 {
        push_len(out, lit - 15);
    }
    out.extend_from_slice(literals);
    if let Some((offset, _)) = m {
        out.extend_from_slice(&(offset as u16).to_le_bytes());
        if ml >= 15 {
            push_len(out, ml - 15);
        }
    }
}

struct Finder<'a> {
    src: &'a [u8],
    head: Vec<i32>,
    prev: Vec<i32>,
    next: usize, // positions below this are in the chains
}

impl<'a> Finder<'a> {
    fn new(src: &'a [u8]) -> Self { Finder { src, head: vec![-1; 1 << HASH_BITS], prev: vec![-1; src.len()], next: 0 } }

    fn insert_to(&mut self, end: usize) {
        while self.next < end {
            let h = hash(self.src, self.next);
            self.prev[self.next] = self.head[h];
            self.head[h] = self.next as i32;
            self.next += 1;
        }
    }

    /// Longest match for position i (ending at most at limit): (offset, length).
    fn best(&mut self, i: usize, limit: usize) -> Option<(usize, usize)> {
        self.insert_to(i);
        let s = self.src;
        let mut cand = self.head[hash(s, i)];
        let mut best: Option<(usize, usize)> = None;
        let mut chain = 0;
        while cand >= 0 && chain < MAX_CHAIN {
            let c = cand as usize;
            let bl = best.map_or(MIN_MATCH - 1, |b| b.1);
            if i + bl < limit && s[c + bl] == s[i + bl] {
                let mut l = 0;
                while i + l < limit && s[c + l] == s[i + l] {
                    l += 1;
                }
                if l > bl {
                    best = Some((i - c, l));
                    if i + l == limit {
                        break;
                    }
                }
            }
            cand = self.prev[c];
            chain += 1;
        }
        best
    }
}

/// Compress one block (offsets stay below 65,536, so blocks up to 64 KiB).
pub fn compress(src: &[u8]) -> Vec<u8> {
    let n = src.len();
    let mut out = Vec::with_capacity(n / 2 + 16);
    let mut anchor = 0;
    if n > MF_LIMIT {
        let match_limit = n - LAST_LITERALS; // matches end here at the latest
        let last_start = n - MF_LIMIT; // and start before this
        let mut f = Finder::new(src);
        let mut i = 0;
        while i < last_start {
            let Some(mut m) = f.best(i, match_limit) else {
                i += 1;
                continue;
            };
            // lazy: a longer match one byte on wins
            if i + 1 < last_start {
                if let Some(m2) = f.best(i + 1, match_limit) {
                    if m2.1 > m.1 + 1 {
                        i += 1;
                        m = m2;
                    }
                }
            }
            sequence(&mut out, &src[anchor..i], Some(m));
            i += m.1;
            anchor = i;
        }
    }
    sequence(&mut out, &src[anchor..], None);
    out
}

#[derive(Debug, PartialEq)]
pub enum Error {
    /// Input ended inside a sequence.
    Truncated,
    /// A match offset of 0 or reaching before the block.
    BadOffset,
    /// More output than the block holds.
    Overflow,
}

/// Decode until out_len bytes are out (bytes after that, such as padding,
/// are ignored). Mirrors what the core's decoder does, byte by byte.
pub fn decompress(src: &[u8], out_len: usize) -> Result<Vec<u8>, Error> {
    let mut out = Vec::with_capacity(out_len);
    let mut i = 0;
    let byte = |i: &mut usize| -> Result<u8, Error> {
        let b = *src.get(*i).ok_or(Error::Truncated)?;
        *i += 1;
        Ok(b)
    };
    while out.len() < out_len {
        let token = byte(&mut i)?;
        let mut lit = (token >> 4) as usize;
        if lit == 15 {
            loop {
                let b = byte(&mut i)?;
                lit += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        for _ in 0..lit {
            let b = byte(&mut i)?;
            if out.len() == out_len {
                return Err(Error::Overflow);
            }
            out.push(b);
        }
        if out.len() == out_len {
            break; // the last sequence has no match
        }
        let offset = byte(&mut i)? as usize | (byte(&mut i)? as usize) << 8;
        if offset == 0 || offset > out.len() {
            return Err(Error::BadOffset);
        }
        let mut len = (token & 15) as usize;
        if len == 15 {
            loop {
                let b = byte(&mut i)?;
                len += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        len += MIN_MATCH;
        if out.len() + len > out_len {
            return Err(Error::Overflow);
        }
        for _ in 0..len {
            out.push(out[out.len() - offset]);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rng(seed: &mut u64) -> u64 {
        *seed ^= *seed << 13;
        *seed ^= *seed >> 7;
        *seed ^= *seed << 17;
        *seed
    }

    fn samples() -> Vec<Vec<u8>> {
        let mut seed = 0x1234_5678_9abc_def1u64;
        let mut v: Vec<Vec<u8>> = vec![vec![], vec![7], vec![0; 4096], (0..4096).map(|i| (i % 251) as u8).collect()];
        v.push((0..4096).map(|_| rng(&mut seed) as u8).collect());
        // text-like, with repeats at many distances and run lengths over 15 and 270
        let words = [&b"pokemon "[..], b"trainer ", b"\x00\x00\x00\x00", b"FFFFFFFFFFFFFFFFFFFF", b"abc"];
        for len in [13usize, 17, 100, 4096] {
            let mut s = vec![];
            while s.len() < len {
                let w = words[(rng(&mut seed) % 5) as usize];
                if rng(&mut seed) % 4 == 0 {
                    s.extend((0..(rng(&mut seed) % 300)).map(|_| rng(&mut seed) as u8));
                }
                s.extend_from_slice(w);
            }
            s.truncate(len);
            v.push(s);
        }
        v.push([vec![9u8; 300], (0..300).map(|_| rng(&mut seed) as u8).collect()].concat());
        v
    }

    #[test]
    fn round_trip() {
        for s in samples() {
            let c = compress(&s);
            assert_eq!(decompress(&c, s.len()).unwrap(), s, "len {}", s.len());
            // padding after the block is ignored
            let mut p = c.clone();
            p.extend([0, 0, 0]);
            assert_eq!(decompress(&p, s.len()).unwrap(), s);
        }
    }

    #[test]
    fn standard_decoder_reads_it() {
        for s in samples() {
            let c = compress(&s);
            assert_eq!(lz4_flex::block::decompress(&c, s.len()).unwrap(), s, "len {}", s.len());
        }
    }

    #[test]
    fn reads_standard_encoder() {
        for s in samples() {
            let c = lz4_flex::block::compress(&s);
            assert_eq!(decompress(&c, s.len()).unwrap(), s);
        }
    }

    #[test]
    fn compresses() {
        assert!(compress(&[0u8; 4096]).len() < 40);
        let s: Vec<u8> = (0..4096).map(|i| (i % 251) as u8).collect();
        assert!(compress(&s).len() < 300);
    }

    #[test]
    fn errors() {
        assert_eq!(decompress(&[], 1), Err(Error::Truncated));
        assert_eq!(decompress(&[0x10, 1, 0, 0, 0], 8), Err(Error::BadOffset)); // offset 0
        assert_eq!(decompress(&[0x10, 1, 2, 0], 8), Err(Error::BadOffset)); // before the block
        assert_eq!(decompress(&[0x1F, 1, 1, 0, 200], 8), Err(Error::Overflow));
        assert_eq!(decompress(&[0x30, 1, 2, 3], 2), Err(Error::Overflow));
    }
}
