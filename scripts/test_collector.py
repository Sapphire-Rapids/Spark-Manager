"""Counter math tests; runs locally without touching the host's Linux paths."""
import importlib.util
import unittest
import sys
from pathlib import Path
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('collector', Path(__file__).parents[1] / 'Sources/SparkMonitor/Resources/collector.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CounterTests(unittest.TestCase):
    def test_cpu_user_system_and_guest_not_double_counted(self):
        before = [0] * 10
        after = [20, 5, 10, 40, 10, 5, 10, 0, 12, 1]
        self.assertEqual(collector.cpu_ratio(before, after), {'usage': 50, 'user': 25, 'system': 25})

    def test_counter_reset_is_gap(self):
        self.assertIsNone(collector.rate(100, 1, 1))
        self.assertIsNone(collector.cpu_ratio([5] * 10, [1] * 10)['usage'])

    def test_real_elapsed_disk_and_network_rates(self):
        self.assertEqual(collector.rate(10, 20, 2, 512), 2560)
        self.assertEqual(collector.rate(100, 1100, 2), 500)
        self.assertEqual(collector.rate(0, 500, 1, .1), 50)


if __name__ == '__main__':
    unittest.main()
