import unittest

import gx_packed as gx


class PackedProtocol(unittest.TestCase):
    def rows(self):
        result = []
        for kind in range(3):
            for length in (1, 2):
                n, entries, words = gx.stream(kind, length)
                for rep in range(3):
                    seq = len(result) + 1
                    result.append([0x47585031, seq, kind, n, rep, entries, len(words), 100, 120,
                                   0x0e000000, 0x06000000, 0x1000, 0, length, gx.input_hash(words), seq])
        return result

    def test_input_vectors_match_executed_frozen_firmware(self):
        # Captured from the frozen C packing code in the headless census run;
        # these are input bits/lengths, not DS timing targets.
        expected = [(1219, 0x5157b893), (2438, 0x7ee7aac5),
                    (1397, 0x97de5715), (2793, 0x78fa0a95),
                    (1350, 0x6b5a179d), (2700, 0xa1da4b75)]
        for pair, (kind, length) in zip(expected, ((k, l) for k in range(3) for l in (1, 2))):
            _, _, words = gx.stream(kind, length)
            self.assertEqual((len(words), gx.input_hash(words)), pair)

    def test_input_corruption_rejected(self):
        rows = self.rows()
        rows[5][14] ^= 1
        with self.assertRaisesRegex(ValueError, 'input'):
            gx.validate(rows)

    def test_early_idle_rejected(self):
        rows = self.rows()
        rows[8][8] = 99
        with self.assertRaisesRegex(ValueError, 'endpoint'):
            gx.validate(rows)

    def bus_lines(self):
        text = []
        for row in self.rows():
            first = row.copy()
            first[15] = 0
            for word, value in enumerate(first):
                text.append(f'WW port {0x3f0100 + word * 4:06x} <= {value:08x} be f')
            # Firmware flushes the full packet, then publishes the commit
            # through a second flush of the last cache line.
            for word in range(8, 16):
                text.append(f'WW port {0x3f0100 + word * 4:06x} <= {row[word]:08x} be f')
        return text

    def test_real_bus_packet_commits_are_required(self):
        text = self.bus_lines()
        decoded = gx.decode_log('\n'.join(text))
        self.assertEqual(decoded, self.rows())
        self.assertEqual(len(gx.validate(decoded)), 18)
        text.pop()
        with self.assertRaisesRegex(ValueError, 'incomplete packet'):
            gx.validate(gx.decode_log('\n'.join(text)))

    def test_missing_unchanged_field_cannot_reuse_previous_packet(self):
        text = self.bus_lines()
        # Kind0 equals both its predecessor and zero-initialized RAM, so
        # value checks alone cannot reveal this missing publication write.
        del text[24 + 2]
        with self.assertRaisesRegex(ValueError, 'incomplete packet'):
            gx.decode_log('\n'.join(text))

    def test_cleared_commit_must_be_observed(self):
        text = self.bus_lines()
        del text[15]
        with self.assertRaisesRegex(ValueError, 'missing cleared commit'):
            gx.decode_log('\n'.join(text))

    def test_duplicate_commit_without_header_rejected(self):
        text = self.bus_lines()
        text.append(text[-1])
        with self.assertRaisesRegex(ValueError, 'without a fresh header'):
            gx.decode_log('\n'.join(text))

    def test_stopped_timer_is_not_a_zero_cost_measurement(self):
        rows = self.rows()
        rows[0][7] = rows[0][8] = 0
        with self.assertRaisesRegex(ValueError, 'endpoint'):
            gx.validate(rows)

    def test_complete_contract_rejects_24_bad_data_cases(self):
        # Twenty-four *negative validation cases*, not twenty-four timed
        # measurements. The frozen firmware publishes exactly eighteen.
        cases = [(f'field-{word}', word, value) for word, value in [
            (0, 0), (1, 2), (2, 1), (3, 76), (4, 1), (5, 1201),
            (6, 1220), (7, 0), (8, 99), (10, 1 << 27), (11, 0),
            (12, 1), (13, 2), (14, 0), (15, 0),
            (7, -1), (8, 1 << 32), (7, 100.0), (12, False)]]
        self.assertEqual(len(cases) + 5, 24)
        for name, word, value in cases:
            with self.subTest(name=name):
                rows = self.rows()
                rows[0][word] = value
                with self.assertRaises(ValueError):
                    gx.validate(rows)
        for count in (0, 17, 19, 24):
            with self.subTest(count=count):
                rows = (self.rows() * 2)[:count]
                with self.assertRaisesRegex(ValueError, '18 committed'):
                    gx.validate(rows)
        rows = self.rows()
        rows[3], rows[4] = rows[4], rows[3]
        with self.assertRaises(ValueError):
            gx.validate(rows)

    def test_missing_each_packet_field_is_rejected(self):
        for word in range(16):
            with self.subTest(word=word):
                # Remove every publication of this field in packet two,
                # including a duplicate in its final cache-line flush.
                lines = self.bus_lines()
                address = f'WW port {0x3f0100 + word * 4:06x}'
                lines[24:48] = [line for line in lines[24:48] if not line.startswith(address)]
                with self.assertRaises(ValueError):
                    gx.validate(gx.decode_log('\n'.join(lines)))

    def test_partial_writes_do_not_replace_full_field_publication(self):
        lines = self.bus_lines()
        lines[24 + 2] = lines[24 + 2].replace('be f', 'be 7')
        with self.assertRaisesRegex(ValueError, 'incomplete packet'):
            gx.decode_log('\n'.join(lines))

    def test_trailing_uncommitted_packet_cannot_be_ignored(self):
        lines = self.bus_lines()
        lines.append('WW port 3f0100 <= 47585031 be f')
        with self.assertRaisesRegex(ValueError, 'end of log'):
            gx.decode_log('\n'.join(lines))


if __name__ == '__main__':
    unittest.main()
