"""Small discriminator checks; these are synthetic images, not DS evidence."""
import unittest

from check_objlimit import code, marker, predict


class MarkerCoverage(unittest.TestCase):
    def setUp(self):
        self.palette = [0] * 512
        self.palette[273:288] = range(0x3e1, 0x3f0)
        self.image = [0] * (256 * 192)

    def draw_rows(self, rows, columns=64):
        # Explicit alternating row vectors independently encode x modulo15
        # and quotient15. Together they identify every column of a marker.
        even = list(range(1, 16)) * 4 + [1, 2, 3, 4]
        odd = [1] * 15 + [2] * 15 + [3] * 15 + [4] * 15 + [5] * 4
        for y in rows:
            for x, index in enumerate((odd if y % 2 else even)[:columns]):
                self.image[(96 + y) * 256 + 128 + x] = 0x83e0 | index

    def test_two_row_codes_identify_all_columns(self):
        pairs = [(code(x, 0), code(x, 1)) for x in range(64)]
        self.assertEqual(pairs[14:17], [(15, 1), (1, 2), (2, 2)])
        self.assertEqual(pairs[-1], (4, 5))
        self.assertEqual(len(set(pairs)), 64)

    def test_common_height_does_not_count_unshared_ballast_lines(self):
        self.draw_rows(range(8))
        common = marker(self.image, self.palette, 1, 128)
        control = marker(self.image, self.palette, 1, 128, lines=64)
        self.assertEqual(common['code_coverage'], 'full')
        self.assertEqual(common['matched_pixels'], 512)
        self.assertEqual(control['code_coverage'], 'nonfull')

    def test_prefix_loss_is_distinct_from_holes_and_from_no_match(self):
        self.draw_rows(range(8), columns=37)
        prefix = marker(self.image, self.palette, 1, 128)
        self.assertEqual(prefix['prefix_columns'], [37] * 8)
        self.assertEqual(prefix['contiguous_prefix_each_line'], [True] * 8)
        self.image[96 * 256 + 128 + 5] = 0
        hole = marker(self.image, self.palette, 1, 128)
        self.assertEqual(hole['prefix_columns'][0], 5)
        self.assertFalse(hole['contiguous_prefix_each_line'][0])
        self.assertEqual(marker(self.image, self.palette, 1, 192)['code_coverage'], 'no-code-match')

    def test_colour_without_capture_valid_bit_is_not_a_match(self):
        self.draw_rows(range(8))
        self.image = [pixel & 0x7fff for pixel in self.image]
        self.assertEqual(marker(self.image, self.palette, 1, 128)['code_coverage'], 'no-code-match')


class CountermodelSeparation(unittest.TestCase):
    def test_count_caps_are_width_invariant_and_obey_swapped_order(self):
        for cap, normal in ((31, [False, False]), (32, [False, False]),
                            (33, [True, False]), (34, [True, True])):
            self.assertEqual(predict(0, cap=cap), [True, True])
            self.assertEqual(predict(5, cap=cap), [True, True])
            for k in (1, 2):
                self.assertEqual(predict(k, cap=cap), normal)
            for k in (3, 4):
                self.assertEqual(predict(k, cap=cap), list(reversed(normal)))

    def test_every_fitted_budget_separates_widths_and_preserves_early_markers(self):
        for budget in range(1771, 1959):
            for k in (0, 1, 3, 5):
                self.assertEqual(predict(k, budget=budget), [True, True])
            for k in (2, 4):
                self.assertEqual(predict(k, budget=budget), [False, False])


if __name__ == '__main__':
    unittest.main()
