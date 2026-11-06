import unittest

from audit_load2d_obj import differences, render


class SceneAmbiguity(unittest.TestCase):
    def test_four_counts_are_observably_equal_but_boundary_counts_are_not(self):
        background = [0x8001] * (256*192)
        expected, _ = render(background, count=32)
        for count in (31, 33, 34):
            self.assertEqual(render(background, count=count)[0], expected)
        for count, pixels in ((30, 128), (35, 64)):
            self.assertEqual(len(differences(render(background, count=count)[0], expected)), pixels)

    def test_distinct_width_budget_has_same_pixels_and_different_selection(self):
        background = [0x8001] * (256*192)
        expected, fixed = render(background, count=32)
        budget, variable = render(background, budget=1800)
        self.assertEqual(budget, expected)
        self.assertNotEqual(fixed, variable)
        self.assertEqual([variable[y] for y in range(0, 192, 32)], [22, 32, 31, 33, 32, 31])


if __name__ == '__main__':
    unittest.main()
