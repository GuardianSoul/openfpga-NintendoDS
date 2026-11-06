#!/usr/bin/env python3
"""Exercise v4's actual journal helpers in a private host directory.

This checks persistence/resume and an I/O failure, not GX/DS timing.
The independent melonDS hardware-probe qualification is still required.
"""
from pathlib import Path
import argparse
import resource
import shutil
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('out', type=Path)
    args = p.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    text = Path(__file__).with_name('main.c').read_text()
    helpers = text[text.index('// A start record'):text.index('void gx_note_timeout')]
    prefix = r'''
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <assert.h>
typedef unsigned int u32;
typedef struct { char* p; size_t len,cap; } Buf;
static bool hw_fat_ok=true;
static u32 g_timeouts,g_reset_fail,g_dropped;
static void hw_status(const char* fmt,...) { (void)fmt; }
static void buf_printf(Buf* b,const char* fmt,...) {
    va_list a;va_start(a,fmt);int n=vsnprintf(NULL,0,fmt,a);va_end(a);
    b->p=realloc(b->p,b->len+n+1);b->cap=b->len+n+1;
    va_start(a,fmt);vsnprintf(b->p+b->len,n+1,fmt,a);va_end(a);b->len+=n;
}
'''
    suffix = r'''
int main(int argc,char** argv) {
    assert(argc==2);int phase=atoi(argv[1]);
    if (phase==3) {hw_fat_ok=false;assert(!start_step("failed",0,0,0,0));assert(!output_ok);return 0;}
    load_progress();assert(resume_step==(phase==1 ? 0u : 5u));
    csv_header("data.csv","step,value\n");
    for (int n=1;n<=(phase==1 ? 5 : 10);n++) {
        bool run=start_step("host",n,0,0,0);
        if (phase==2 && n<=5) {assert(!run);continue;}
        assert(run);if(phase==1 && n==5) break; // simulate hang after durable START
        Buf row={0};buf_printf(&row,"%d,%d\n",n,n*2);append(&row,"data.csv");done_step();
    }
    assert(output_ok);return 0;
}
'''
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    # Match FAT's short root: the embedded helper intentionally has a bounded
    # 96-byte path buffer, unlike this long worktree's host artifact path.
    fat_root = Path(tempfile.mkdtemp(prefix='gxv4-'))
    (out / 'temporary-root.txt').write_text(str(fat_root) + '\n')
    for variant in ('good', 'skip_only_done'):
        work = fat_root / variant
        work.mkdir(exist_ok=False)
        code = helpers
        if variant != 'good':
            old = 'sscanf(line,"START,%lu",&n)'
            assert code.count(old) == 1
            code = code.replace(old, 'sscanf(line,"DONE,%lu",&n)')
        source = out / f'{variant}.c'
        source.write_text(f'#define HWREF_DIR "{work}"\n' + prefix + code + suffix)
        exe = out / f'{variant}-test'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(exe)], check=True)
        subprocess.run([str(exe), '1'], check=True)
        r = subprocess.run([str(exe), '2'], capture_output=True, text=True)
        (out / f'{variant}.log').write_text(r.stdout + r.stderr)
        if variant != 'good':
            assert r.returncode != 0 and 'resume_step' in r.stderr
            shutil.copytree(work, out / variant)
            print(f'Caught DONE-only resume mutation: exit {r.returncode}')
            continue
        assert r.returncode == 0, r.stderr
        lines = (work / 'data.csv').read_text().splitlines()
        assert lines == ['step,value'] + [f'{n},{2*n}' for n in [1, 2, 3, 4, 6, 7, 8, 9, 10]]
        journal = (work / 'gxlatency_v4_progress.txt').read_text().splitlines()
        assert sum(x.startswith('START,') for x in journal) == 10
        assert sum(x.startswith('DONE,') for x in journal) == 9
        subprocess.run([str(exe), '3'], check=True)
        assert (work / 'gxlatency_v4_progress.txt').read_text().splitlines() == journal
        shutil.copytree(work, out / variant)
        print('Resume skips hung step, preserves nine rows/one header; I/O failure blocks execution')
    shutil.rmtree(fat_root)


if __name__ == '__main__':
    main()
