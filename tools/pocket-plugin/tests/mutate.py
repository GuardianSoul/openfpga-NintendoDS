#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Plants bugs in the plugin and its reference decoder; each must make the
unit tests or tests/check_roms.py (on one ROM) fail. The files are restored
after each run.

  python3 tests/mutate.py ../../roms/nsmb.nds
"""
from pathlib import Path
import subprocess
import sys

PLUGIN = Path(__file__).resolve().parents[1]

MUTATIONS = [
    ('read-ahead capped at 3', 'src/rom.rs', 'pub const MAX_AHEAD: u32 = 4;', 'pub const MAX_AHEAD: u32 = 3;'),
    ('blocks from the span start, not its first whole block', 'src/rom.rs',
     'let (sb, se) = (ceil_blk(s), ceil_blk(end));', 'let (sb, se) = (s as u64 >> BLOCK_SHIFT, ceil_blk(end));'),
    ('ARM7 binary left out', 'src/rom.rs', '            (h.arm7.rom_offset, h.arm7.rom_offset.wrapping_add(h.arm7.size)),\n', ''),
    ('scan budget 2 x blocks', 'src/rom.rs', 'let mut budget = n * 4;', 'let mut budget = n * 2;'),
    ('room counts the block itself', 'src/rom.rs', 'let room = (se - 1 - b)', 'let room = (se - b)'),
    ('match offsets off by one', 'src/lz4.rs', 'out.extend_from_slice(&(offset as u16).to_le_bytes());',
     'out.extend_from_slice(&(offset as u16 + 1).to_le_bytes());'),
    ('decoder skips the last literal', 'src/lz4.rs', '        for _ in 0..lit {\n            let b = byte(&mut i)?;',
     '        for _ in 0..lit.saturating_sub(1) {\n            let b = byte(&mut i)?;'),
    ('raw blocks never used', 'src/formats.rs', 'if round4(c.len()) >= round4(raw.len()) {', 'if false {'),
    ('save type without its valid bit', 'src/rom.rs', 'Ok(i) if crate::romlist::ROMLIST[i].1 <= 7 => 1 << 31 |', 'Ok(i) if crate::romlist::ROMLIST[i].1 <= 7 => 0 |'),
    ('NAND saves passed on', 'src/rom.rs', 'crate::romlist::ROMLIST[i].1 <= 7 =>', 'crate::romlist::ROMLIST[i].1 <= 10 =>'),
    ('index off by 4', 'src/formats.rs', 'let mut at = data_at;', 'let mut at = data_at + 4;'),
    ('reference: matches copy from one byte later', 'ref/ndz.py', 'out.append(out[-offset])', 'out.append(out[-offset + 1] if offset > 1 else out[-1])'),
    ('reference: raw test off', 'ref/ndz.py', 'if len(stored) >= (raw_len + 3) & ~3:', 'if len(stored) > (raw_len + 3) & ~3:'),
]


def main():
    roms = sys.argv[1:]
    if not roms:
        sys.exit(__doc__)
    caught = 0
    for what, file, old, new in MUTATIONS:
        path = PLUGIN / file
        text = path.read_text()
        assert text.count(old) == 1, f'{what}: pattern not found once in {file}'
        path.write_text(text.replace(old, new))
        try:
            unit = subprocess.run(['cargo', 'test', '-q'], cwd=PLUGIN, capture_output=True).returncode != 0
            roms_failed = subprocess.run([sys.executable, str(PLUGIN / 'tests/check_roms.py'), *roms], cwd=PLUGIN,
                                         capture_output=True).returncode != 0
        finally:
            path.write_text(text)
        by = ' + '.join(n for n, hit in (('unit tests', unit), ('check_roms', roms_failed)) if hit) or 'NOTHING'
        caught += by != 'NOTHING'
        print(f'{"caught" if by != "NOTHING" else "MISSED"}  {what:55s} by {by}')
    print(f'{caught} of {len(MUTATIONS)} mutations caught')
    sys.exit(0 if caught == len(MUTATIONS) else 1)


if __name__ == '__main__':
    main()
