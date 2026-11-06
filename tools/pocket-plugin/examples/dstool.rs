// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin's formats on the command line, for tests and measurements:
//   dstool ndt ROM OUT.ndt       ROM tables
//   dstool ndz ROM OUT.ndz       compressed ROM
//   dstool unndz IN.ndz OUT.nds  decompress (checks the CRC-32)
//   dstool info ROM|NDZ          header, FAT and table as JSON
use plugin::{formats, games, rom};
use std::fs;
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;
use std::time::Instant;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let arg = |i: usize| a.get(i).map(String::as_str).unwrap_or_else(|| { eprintln!("usage: dstool ndt|ndz|unndz|info IN [OUT]"); std::process::exit(2) });
    match arg(1) {
        "ndt" => fs::write(arg(3), formats::ndt(&games::read_rom(Path::new(arg(2))).unwrap())).unwrap(),
        "ndz" => {
            let t = Instant::now();
            let size = fs::metadata(arg(2)).unwrap().len();
            let open = || BufReader::new(fs::File::open(arg(2)).unwrap());
            let plan = formats::plan_ndz(&mut open(), size, &mut |_| {}).unwrap();
            let mut out = BufWriter::new(fs::File::create(arg(3)).unwrap());
            formats::write_ndz(&mut open(), &plan, &mut out, &mut |_| {}).unwrap();
            out.flush().unwrap();
            let raw = plan.lens.iter().filter(|&&l| l as u64 >= rom::BLOCK).count();
            println!("{{\"rom\": {size}, \"ndz\": {}, \"ratio\": {:.4}, \"raw_blocks\": {raw}, \"blocks\": {}, \"seconds\": {:.2}}}",
                plan.file_size(), size as f64 / plan.file_size() as f64, plan.lens.len(), t.elapsed().as_secs_f64());
        }
        "unndz" => {
            let mut out = BufWriter::new(fs::File::create(arg(3)).unwrap());
            formats::decompress_ndz(&mut BufReader::new(fs::File::open(arg(2)).unwrap()), &mut out).unwrap();
            out.flush().unwrap();
        }
        "info" => {
            let r = games::read_rom(Path::new(arg(2))).unwrap();
            let t = r.table();
            let h = &r.header;
            let bin = |b: &rom::Binary| format!("[{}, {}, {}, {}]", b.rom_offset, b.entry, b.ram_address, b.size);
            let fat: Vec<String> = r.fat.iter().map(|(s, e)| format!("[{s},{e}]")).collect();
            let names: Vec<String> = r.streams.iter().map(|i| i.to_string()).collect();
            println!("{{\"size\": {}, \"game_code\": {}, \"crc_ok\": {}, \"arm9\": {}, \"arm7\": {}, \"fnt\": [{}, {}], \"fat_at\": [{}, {}], \"fat\": [{}], \"streams\": [{}], \"table\": [{}], \"capped\": {}}}",
                r.size, h.game_code, h.crc_ok, bin(&h.arm9), bin(&h.arm7), h.fnt_offset, h.fnt_size, h.fat_offset, h.fat_size,
                fat.join(","), names.join(","), t.words.iter().map(|w| w.to_string()).collect::<Vec<_>>().join(","), t.capped);
        }
        _ => { eprintln!("unknown command"); std::process::exit(2) }
    }
}
