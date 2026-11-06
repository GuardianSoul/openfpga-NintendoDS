#!/usr/bin/env python3
"""Turn a packaged DS build into the public release zip (docs/public-release.md).

Takes the package folder that scripts/build_ds.sh writes with
tools/ds/package.py (only when timing passed) and makes
GuardianSoul.NintendoDS_<version>_<date>.zip, Analogue's recommended name,
the way openfpga-PlayStation's scripts/package_release.py does for the PlayStation core:

- the core is renamed to GuardianSoul.NintendoDS on platform nds, with the
  public metadata and info text;
- the boot ROM moves to Assets/nds/GuardianSoul.NintendoDS/;
- the platform, its image, the core icon, the GPL-3 text and every licence
  the bitstream needs go in.

It refuses a build whose result.txt doesn't say timing PASS, a diagnostics
core, a missing save or boot ROM slot, or any workspace name left in the
package. Workspace test builds keep their own names (tools/ds/package.py).

  python3 tools/ds/package_release.py build/ds/package --result build/ds/result.txt --version 0.5.0-rc1
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pocket_image  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
AUTHOR = 'GuardianSoul'
SHORTNAME = 'NintendoDS'
CORE = f'{AUTHOR}.{SHORTNAME}'
REPO = f'https://github.com/{AUTHOR}/openfpga-NintendoDS'
PLATFORM = 'nds'
SOURCE_CORES = ('GuardianSoul.NintendoDS', CORE)        # the workspace packager's core id (and its named builds, GuardianSoul.NintendoDSPlayRC1), and the public one
SOURCE_PLATFORMS = ('ds', PLATFORM)
LICENSES = (                               # (source, name in the core's licenses folder)
    (ROOT/'licenses/MIT.txt', 'MIT.txt'),
    (ROOT/'licenses/Apache-2.0.txt', 'Apache-2.0.txt'),
    (ROOT/'rtl/apf/MIRLO64-NOTICE.txt', 'MIRLO64-NOTICE.txt'),
    (ROOT/'rtl/serv/LICENSE', 'SERV-LICENSE.txt'),
    (ROOT/'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md'),
)
# One line per paragraph: the Pocket wraps info.txt itself.
INFO = """Nintendo DS core for Analogue Pocket by {author}.

You need your own DS BIOS and firmware (bios9.bin, bios7.bin and firmware.bin in Assets/nds/common) and your own .nds games, in the same folder. Games start directly, without the DS menu.

Saves go to Saves/nds/common when you quit through the Pocket menu, so quit before turning the Pocket off.

Select + L or R changes the screen layout. Select + A, B, X or Y turns touch mode on or off; in touch mode the D-Pad moves the cursor and A touches. Core Settings change this.

Setup, controls and source: {repo}. The core is GPL-3.0-or-later; see the licenses folder.
"""
PLATFORM_JSON = {'platform': {'category': 'Handheld', 'name': 'Nintendo DS', 'year': 2004, 'manufacturer': 'Nintendo'}}
# workspace author names (none left in the public tree) and private paths
PRIVATE = re.compile('|'.join([*(re.escape(c.split('.')[0]) for c in SOURCE_CORES if not c.startswith(AUTHOR)),
                               r'/(?:home|run/media|tmp)/']), re.I)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('package', type=Path, help='tools/ds/package.py output folder (holds SD/)')
    parser.add_argument('--result', type=Path, required=True, help="build_ds.sh's result.txt")
    parser.add_argument('--version', required=True)
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    parser.add_argument('--output', type=Path, default=ROOT/'build/release')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+(-rc\d+)?', args.version): parser.error('version must look like 0.5.0 or 0.5.0-rc1')
    result = args.result.read_text()
    if not re.search(r'timing PASS', result): parser.error(f'{args.result}: timing did not pass')
    package = args.package.resolve()
    cores = [c for c in (package/'SD/Cores').iterdir() if c.name.startswith(SOURCE_CORES)]
    if len(cores) != 1: parser.error(f'expected one of {SOURCE_CORES} in {package}/SD/Cores')
    source_platform = next((p for p in SOURCE_PLATFORMS if (package/f'SD/Platforms/{p}.json').is_file()), None)
    if not source_platform: parser.error('package has no DS platform')

    out = args.output.resolve(); sd = out/'SD'
    if sd.exists(): shutil.rmtree(sd)
    core = sd/'Cores'/CORE
    shutil.copytree(cores[0], core)
    def load(name): return json.loads((core/name).read_text())
    def write(name, value): (core/name).write_text(json.dumps(value, indent=2)+'\n')

    data = load('data.json')
    slots = {int(str(s['id']), 0): s for s in data['data']['data_slots']}
    if 11 in slots: parser.error('diagnostics slot present: package a normal build, not NDSDiag')
    if 10 not in slots or not slots[10].get('nonvolatile'): parser.error('save slot missing')
    if 12 not in slots or slots[12].get('filename') != 'nds_boot.bin': parser.error('boot ROM slot missing')
    boot = package/'SD/Assets'/source_platform/cores[0].name/'nds_boot.bin'
    if not boot.is_file(): parser.error(f'{boot} missing')
    (sd/'Assets'/PLATFORM/CORE).mkdir(parents=True)
    shutil.copyfile(boot, sd/'Assets'/PLATFORM/CORE/'nds_boot.bin')

    meta = load('core.json')
    # APF caps core.json descriptions at 63 characters.
    meta['core']['metadata'].update(platform_ids=[PLATFORM], shortname=SHORTNAME,
        description='A Nintendo DS core for the Analogue Pocket', author=AUTHOR, url=REPO,
        version=args.version, date_release=args.date)
    write('core.json', meta)
    (core/'info.txt').write_text(INFO.format(author=AUTHOR, repo=REPO))

    shutil.copyfile(ROOT/'LICENSE', core/'LICENSE.txt')
    notices = core/'licenses'; shutil.rmtree(notices, ignore_errors=True); notices.mkdir()
    for source, name in LICENSES: shutil.copyfile(source, notices/name)
    (core/'icon.bin').write_bytes(pocket_image.encode(ROOT/'support/pocket-art/core-icon.png', (36, 36)))

    (sd/'Platforms/_images').mkdir(parents=True)
    (sd/'Platforms'/f'{PLATFORM}.json').write_text(json.dumps(PLATFORM_JSON, indent=2)+'\n')
    (sd/'Platforms/_images'/f'{PLATFORM}.bin').write_bytes(
        pocket_image.encode(ROOT/'support/pocket-art/ds-banner.png', (521, 165)))
    assets = sd/'Assets'/PLATFORM/'common'; assets.mkdir(parents=True)
    (assets/'PLACE-BIOS-AND-GAMES-HERE.txt').write_text(
        'Place your own DS BIOS and firmware dumps here: bios9.bin (4,096 bytes), bios7.bin (16,384 bytes) '
        'and firmware.bin (262,144 bytes on a DS or DS Lite). Put your .nds games here too.\n'
        'No BIOS, firmware or game is included.\n')

    for path in sorted(sd.rglob('*')):
        if path.is_file() and path.suffix not in {'.rbf_r', '.bin'}:
            if PRIVATE.search(path.read_text(errors='replace')) or PRIVATE.search(str(path.relative_to(sd))):
                raise SystemExit(f'workspace name left in {path.relative_to(sd)}')
    archive_path = out/f'{CORE}_{args.version}_{args.date}.zip'
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(sd.rglob('*')):
            if path.is_file(): archive.write(path, path.relative_to(sd))
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    (out/'release-report.json').write_text(json.dumps(dict(
        version=args.version, date=args.date, source_package=str(package),
        fit_result=[l for l in result.splitlines() if l.startswith('RESULT')],
        rbf_r_sha256=digest(core/'bitstream.rbf_r'), zip=archive_path.name, zip_sha256=digest(archive_path)), indent=2)+'\n')
    print(archive_path)


if __name__ == '__main__': main()
