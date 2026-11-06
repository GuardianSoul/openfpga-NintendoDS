"""Synthetic DS-CSV pairing checks; these values are not hardware targets."""
from copy import deepcopy
import unittest

import compare_gx_packed as comparison
import gx_packed as gx
import test_gx_packed


class MatchedInputs(unittest.TestCase):
    def rows(self):
        rows = gx.validate(test_gx_packed.PackedProtocol().rows())
        result = []
        for row in rows:
            result.append({key: f'{value:08x}' if key in ('dma_gxstat', 'idle_gxstat', 'clip0_after_idle')
                           else str(value) for key, value in row.items() if key != 'stream_fnv1a32'})
        return result

    def test_all18_ds_inputs_and_both_endpoints_match(self):
        decoded = comparison.ds_rows(self.rows())
        self.assertEqual(decoded, gx.validate(test_gx_packed.PackedProtocol().rows()))
        self.assertEqual(len(decoded), 18)

    def test_ds_missing_row_duplicate_input_and_bad_data_rejected(self):
        for mutation in ('missing', 'duplicate', 'body', 'words', 'busy', 'clip', 'earlyidle', 'timeout'):
            with self.subTest(mutation=mutation):
                rows = self.rows()
                if mutation == 'missing':
                    rows.pop()
                elif mutation == 'duplicate':
                    rows[7] = deepcopy(rows[6])
                else:
                    key, value = dict(body=('body', 'LOAD43'), words=('words', '1'),
                                      busy=('idle_gxstat', '08000000'), clip=('clip0_after_idle', '0'),
                                      earlyidle=('idle_sys', '99'), timeout=('timeout', '1'))[mutation]
                    rows[0][key] = value
                with self.assertRaises(ValueError):
                    comparison.ds_rows(rows)

    def test_dma_and_idle_slopes_cannot_be_swapped(self):
        rows = comparison.ds_rows(self.rows())
        for row in rows:
            row['dma_sys'] = row['n'] * 2 + 100
            row['idle_sys'] = row['n'] * 3 + 1000
        summary = comparison.summarize(rows)
        for group in summary:
            self.assertEqual(group['dma_sys']['median_group_slope'], 2)
            self.assertEqual(group['idle_sys']['median_group_slope'], 3)
            self.assertEqual(group['dma_sys']['paired_slopes'], [2] * 3)

    def test_pre_protocol_writes_scoped_without_relaxing_freshness(self):
        packet_log = '\n'.join(test_gx_packed.PackedProtocol().bus_lines())
        prefix = 'WW port 3f013c <= 70a26f4e be f\n'
        projected, scope = comparison.protocol_log(prefix + packet_log)
        self.assertEqual(projected, packet_log)
        self.assertEqual(scope['pre_protocol_port_writes'], 1)
        self.assertEqual(gx.decode_log(projected), gx.decode_log(packet_log))
        # A duplicate commit after publication begins cannot be filtered.
        projected, _ = comparison.protocol_log(prefix + packet_log + '\n' + packet_log.splitlines()[-1])
        with self.assertRaisesRegex(ValueError, 'without a fresh header'):
            gx.decode_log(projected)

    def test_missing_first_header_cannot_be_replaced_by_packet_two(self):
        lines = test_gx_packed.PackedProtocol().bus_lines()
        del lines[0]
        projected, _ = comparison.protocol_log('\n'.join(lines))
        with self.assertRaisesRegex(ValueError, 'missing, repeated or reordered'):
            gx.decode_log(projected)


if __name__ == '__main__':
    unittest.main()
