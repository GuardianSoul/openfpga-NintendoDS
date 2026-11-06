import importlib
import unittest

import gx_packed_current as current


class ExplicitProfile(unittest.TestCase):
    def setUp(self):
        importlib.reload(current)

    def tearDown(self):
        importlib.reload(current)

    def test_child_mode_missing_changed_or_duplicate_is_rejected(self):
        current.select_revision('cc00')
        self.assertEqual(current.PROFILE['GX_DSX'], 1)
        self.assertEqual((current.QUALIFICATION, current.QUALIFICATION_CHECKS), ('itcm-control', 7))
        banner = 'DS_GX_ROUTE_OK: DSX1 CHEAP0 AHEAD1'
        current.check_route(banner)
        for text in ['', banner.replace('DSX1', 'DSX0'), banner.replace('CHEAP0', 'CHEAP1'),
                     banner.replace('AHEAD1', 'AHEAD0'), banner + '\n' + banner]:
            with self.subTest(text=text):
                with self.assertRaisesRegex(ValueError, 'GX DSX/child route'):
                    current.check_route(text)

    def test_explicit921_restores_its_frozen_profile_after_cc00(self):
        current.select_revision('cc00')
        current.select_revision('921')
        self.assertEqual(current.PROFILE, dict(A9_WAYS=4, A9_XD=0, A9_XI=0,
                                              A9_OPT=461366243, DMA_RA=2, DX_SKID=1))
        self.assertEqual((current.QUALIFICATION, current.QUALIFICATION_CHECKS), ('unitmem', 32))
        self.assertEqual((current.ROUTE_GUARDS, current.EXTRA_ASSERTIONS), ((), ()))
        current.check_route('historical log has no DSX banner')


if __name__ == '__main__':
    unittest.main()
