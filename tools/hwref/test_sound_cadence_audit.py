import unittest

from audit_sound_cadence import periodic, step


class CadenceEvidence(unittest.TestCase):
    def test_change_spacing_does_not_replace_waveform_period(self):
        ds = periodic(([0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7] * 64))
        core = periodic(([1]*4 + [3]*4 + [5]*4 + [7]*4) * 64)
        self.assertEqual((ds['fundamental_period'], core['fundamental_period']), (16, 16))
        self.assertNotEqual(ds['change_gaps'], core['change_gaps'])
        twice_rate = periodic(([0, 1, 2, 3, 4, 5, 6, 7] * 128))
        self.assertEqual(twice_rate['fundamental_period'], 8)

    def test_odd_pcm16_tail_is_outside_programmed_word_count(self):
        a = step([0, 0, 8192, 8192, 0])
        b = step([0, 0, 8192, 8192, 8192])
        self.assertEqual(a['programmed_samples'], 4)
        self.assertEqual(a['transitions'], [2])
        self.assertEqual(a['transitions'], b['transitions'])
        self.assertNotEqual(a['unqualified_tail'], b['unqualified_tail'])


if __name__ == '__main__':
    unittest.main()
