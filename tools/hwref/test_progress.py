"""Run the actual C journal helpers against a temporary host filesystem."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = (Path(__file__).resolve().parents[2] / 'sw/hwref/common/hwref.c').read_text()
        helpers = source[source.index('bool hw_write('):source.index('void hw_done(')]
        text = '''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#define iprintf printf
static bool hw_fat_ok=true, s_write_failed;
''' + helpers + '''
int main(int argc, char** argv) {
 if(argc<3)return 2;
 bool ok=false;
 if(!strcmp(argv[1],"begin"))ok=hw_step_begin("progress.txt",argv[2]);
 if(!strcmp(argv[1],"done"))ok=hw_step_done("progress.txt",argv[2]);
 if(!strcmp(argv[1],"header"))ok=hw_csv_header("rows.csv",argv[2]);
 if(!strcmp(argv[1],"append"))ok=hw_append("rows.csv",argv[2],strlen(argv[2]));
 if(!strcmp(argv[1],"write"))ok=hw_write(argv[2],"x",1);
 printf("result %d failed %d\\n",ok,s_write_failed);
 return ok ? 0 : 1;
}
'''
        c = self.root / 'progress.c'
        c.write_text(text)
        self.binary = self.root / 'progress'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Werror',
                        f'-DHWREF_DIR="{self.root}"', str(c), '-o', str(self.binary)],
                       check=True, capture_output=True)

    def call(self, action, key):
        return subprocess.run([str(self.binary), action, key], text=True, capture_output=True)

    def test_completed_step_is_not_repeated_or_rewritten(self):
        self.assertEqual(self.call('begin', 'case1').returncode, 0)
        self.assertEqual(self.call('done', 'case1').returncode, 0)
        path = self.root / 'progress.txt'
        saved = path.read_bytes()
        self.assertEqual(self.call('begin', 'case1').returncode, 1)
        self.assertEqual(path.read_bytes(), saved)

    def test_interrupted_step_is_skipped_and_next_can_run(self):
        self.assertEqual(self.call('begin', 'hung').returncode, 0)
        self.assertEqual(self.call('begin', 'hung').returncode, 1)
        self.assertEqual(self.call('begin', 'next').returncode, 0)
        self.assertNotIn('done hung', (self.root / 'progress.txt').read_text())

    def test_csv_header_does_not_truncate_prior_results(self):
        self.assertEqual(self.call('header', 'columns\n').returncode, 0)
        self.assertEqual(self.call('append', 'row1\n').returncode, 0)
        self.assertEqual(self.call('header', 'columns\n').returncode, 0)
        self.assertEqual((self.root / 'rows.csv').read_text(), 'columns\nrow1\n')

    def test_oversized_write_path_is_rejected(self):
        result = self.call('write', 'x' * 200)
        self.assertEqual(result.returncode, 1)
        self.assertIn('failed 1', result.stdout)


if __name__ == '__main__':
    unittest.main()
