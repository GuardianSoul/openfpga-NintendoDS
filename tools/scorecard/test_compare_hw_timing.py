import unittest

from compare_hw_timing import observation, slope


class RawBests(unittest.TestCase):
    def test_actual_ds35_raw_bests_round_per_ldm_not_per_word(self):
        self.assertEqual(slope(5949, 23709, 768, True), 2313)
        self.assertEqual(slope(5949, 23709, 768, False), 2312)
        with self.assertRaisesRegex(ValueError, 'contradicts raw bests'):
            observation('word-normalization mutant', 289, 5949, 23709, 2313, True)

    def test_bests_cannot_be_reversed_zero_or_floating(self):
        for short, long in [(0, 100), (100, 100), (101, 100), (1.0, 100)]:
            with self.subTest(short=short, long=long):
                with self.assertRaises(ValueError):
                    slope(short, long, 768, False)

    def test_too_fast_observation_is_retained_without_pass(self):
        row = observation('synthetic fast control', 200, 100, 1636, 306, False)
        self.assertEqual(row['difference_x100'], -106)
        self.assertFalse(row['same_rounded_value'])
        self.assertIn('no automatic timing PASS', row['status'])


if __name__ == '__main__':
    unittest.main()
