"""The display coordinates here are logical CoreGraphics coordinates (Y grows down)."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("aerospace_layout", Path(__file__).resolve().parents[1] / "aerospace-layout.py")
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


def screen(x, y, builtin=False):
    return dict(x=x, y=y, width=2560, height=1440, builtin=builtin, name="Display", mirror=False)


class GeometryTests(unittest.TestCase):
    def positions(self, displays, monitor_ids):
        monitors = [{"monitor-appkit-nsscreen-screens-id": i, "monitor-id": n, "monitor-name": "Display"}
                    for i, n in enumerate(monitor_ids, 1)]
        return layout.display_positions(displays, monitors)

    def test_left_right_follow_position_and_ignore_builtin_and_appkit_order(self):
        self.assertEqual(self.positions([screen(0, 0), screen(-5120, 80, True), screen(-2560, -70)], [3, 1, 2]),
                         {"left": 2, "right": 3, "mac": 1})

    def test_vertical_offset_reverses_numeric_monitor_order(self):
        self.assertEqual(self.positions([screen(80, -1440), screen(0, 0)], [2, 1]), {"top": 2, "bottom": 1})

    def test_diagonal_tie_uses_horizontal_axis(self):
        self.assertEqual(self.positions([screen(0, 0), screen(2560, 2560)], [1, 2]), {"left": 1, "right": 2})

    def test_mirror_and_single_display(self):
        self.assertEqual(self.positions([screen(0, 0, True), dict(screen(0, 0), mirror=True)], [1, 1]), {"mac": 1})
        self.assertEqual(self.positions([screen(0, 0)], [1]), {"single": 1})

    def test_missing_display_fails_before_window_moves(self):
        with self.assertRaises(ValueError):
            self.positions([screen(0, 0), screen(0, 1440)], [1])
