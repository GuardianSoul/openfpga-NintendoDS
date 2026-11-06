# DS Game Files (Pocket plugin)

A [Pocket plugin](https://github.com/openfpga-library/pocket-plugin) for
Pocket Sync and pupdate, for the NDS_Pocket DS core. For the games in
`Assets/nds/common/` it writes:

- `<game>.ndt`, the **ROM tables**: the ROM cache's read-ahead table (from
  the NitroFS file table), the game's save type (from melonDS's game list)
  and the header's boot fields, so the core doesn't work them out itself;
- `Assets/nds/<core>/<game>.json`, the **game file** that loads the ROM with
  its tables, once the core's `data.json` has the slots for it;
- optionally `<game>.ndz`, a **compressed ROM** (4 KiB LZ4 blocks with an
  index) for faster loading, once the core reads them. Until then it is
  behind the config `compress=1`.

The formats, the core side and the measurements are in
[docs/pocket-plugin.md](../../docs/pocket-plugin.md).

Modelled on openfpga-PlayStation's plugin, with its SD card safety rules:
- every large file first claims its size plus 256 MB;
- a file gets its real name only after it is written, synced and read back
  (a `.ndz` is also decompressed and compared with its ROM);
- originals are removed only after that;
- a stopped run is finished or cleaned up by the next one.

## Build

```
scripts/build.sh               # target/wasm32-wasip1/release/plugin.wasm
```

`scripts/build.sh` is `cargo build --release --locked --target wasm32-wasip1`
with the build machine's folders removed from the paths Rust keeps in the
binary. Plain `cargo` commands build for the computer, for the tests.

## Tests

```
cargo test                                     # unit tests
python3 tests/check_roms.py ../../roms/*.nds   # melonDS header, RTL table, round trip
python3 tests/mutate.py ../../roms/nsmb.nds    # planted bugs must be caught
python3 tests/test_plugin.py                   # plugin.wasm on test cards (pip install extism)
```

`check_roms.py` needs Verilator (`TOOLS`, default openfpga-PlayStation's
oss-cad-suite) and `references/melonDS`. ROMs are only read.

`scripts/romlist.py` regenerates `src/romlist.rs` from
`references/melonDS/src/ROMList.cpp` after a melonDS update.

`ref/ndz.py` is the reference decoder for `.ndz`, to test the core's RTL
against. `examples/dstool.rs` (`cargo run --release --example dstool`)
writes and reads the formats on the command line.

## Run

```
python3 host/run_plugin.py target/wasm32-wasip1/release/plugin.wasm /path/to/sd-card --answer "Generate Game Files"
```

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). The plugin carries the save type of
each game from [melonDS](https://github.com/melonDS-emu/melonDS)'s game list
(`src/ROMList.cpp`, GPL-3.0-or-later, the melonDS team; generated into
`src/romlist.rs` by `scripts/romlist.py`). Thanks to the melonDS team.

The plugin is a separate program from the DS core, which is also GPL-3.0-or-later: it
runs on the computer, and the core only reads the files it writes.

`plugin.wasm` also contains the Rust crates listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
(`python3 scripts/third_party.py` regenerates it).
