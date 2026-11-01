"""Regression checks without moving real windows or writing ~/.aerospace.toml."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(os.environ.get("HELPER_UNDER_TEST", str(ROOT / "aerospace-ws.sh")))


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aerospace-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        binary = self.root / "aerospace"
        shutil.copyfile(ROOT / "tests/fake_aerospace.py", binary)
        binary.chmod(0o755)
        ioreg = self.root / "ioreg"
        ioreg.write_text('#!/usr/bin/env python3\nimport json, os\n'
                         'mode = json.load(open(os.environ["AEROSPACE_TEST_STATE"]))["mode"]\n'
                         'print(\'"AppleClamshellState" = \' + ("Yes" if mode == "ext" else "No"))\n')
        ioreg.chmod(0o755)
        self.state_file = self.root / "server.json"
        self.state_dir = self.root / "state/aerospace"
        self.state_dir.mkdir(parents=True)
        self.mode_file = self.state_dir / "mode"
        self.origins = self.state_dir / "origins"
        self.env = dict(os.environ, PATH=str(self.root) + ":/usr/bin:/bin",
                        XDG_STATE_HOME=str(self.root / "state"), AEROSPACE_TEST_STATE=str(self.state_file))
        for key in ("AEROSPACE_WS_LOCKED", "AEROSPACE_WINDOW_ID", "AEROSPACE_WORKSPACE"):
            self.env.pop(key, None)
        self.state = {"mode": "ext", "focused": "main-top", "focused_window": "10",
                      "visible": {"1": "main-top", "2": "hacking-bottom"},
                      "windows": {"10": {"workspace": "main-top", "monitor": "1"},
                                  "20": {"workspace": "hacking-bottom", "monitor": "2"}}}
        self.mode_file.write_text("ext\n")

    def run_helper(self, *args, success=True):
        self.state_file.write_text(json.dumps(self.state))
        result = subprocess.run(["/bin/bash", str(HELPER), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.state = json.loads(self.state_file.read_text())
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_cycle_bottom_from_top_focus(self):
        self.run_helper("cycle", "next", "bottom", "search", "hacking", "main", "other")
        self.assertEqual(self.state["focused"], "main-bottom")

    def test_cycle_previous_wraps_on_target_monitor(self):
        self.state["visible"]["2"] = "search-bottom"
        self.run_helper("cycle", "prev", "bottom", "search", "hacking", "main", "other")
        self.assertEqual(self.state["focused"], "other-bottom")

    def test_move_keeps_original_window_during_sync(self):
        self.mode_file.write_text("all\n")
        self.state["visible"]["1"] = self.state["focused"] = "1"
        self.state["windows"]["10"]["workspace"] = "1"
        self.run_helper("move", "other", "bottom")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "other-bottom")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-bottom")

    def test_failed_restore_is_retried(self):
        self.mode_file.write_text("mac\n")
        self.origins.write_text("10 bottom\n")
        self.state["windows"]["10"]["workspace"] = "other-mac"
        self.state["fail_moves"] = ["10"]
        self.run_helper("sync", success=False)
        self.assertEqual(self.origins.read_text(), "10 bottom\n")
        self.assertEqual(self.mode_file.read_text().strip(), "mac")
        self.state["fail_moves"] = []
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "other-bottom")
        self.assertEqual(self.origins.read_text(), "")

    def test_query_failure_preserves_restore_journal(self):
        self.mode_file.write_text("mac\n")
        self.origins.write_text("10 bottom\n")
        self.state["fail_commands"] = ["list-windows"]
        self.run_helper("sync", success=False)
        self.assertEqual(self.origins.read_text(), "10 bottom\n")
        self.assertEqual(self.mode_file.read_text().strip(), "mac")

    def test_laptop_collapse_remembers_position_after_role_change(self):
        self.state["mode"] = "mac"
        self.state["visible"] = {"1": "main-top"}
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-mac")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-mac")
        self.state["windows"]["20"]["workspace"] = "other-mac"
        self.state["mode"] = "ext"
        self.state["visible"] = {"1": "main-top", "2": "hacking-bottom"}
        self.state["focused"] = "main-top"
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-top")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "other-bottom")

    def test_new_mac_window_is_drained_even_without_mode_change(self):
        self.state["windows"]["20"]["workspace"] = "other-mac"
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "other-top")

    def test_callback_context_does_not_override_global_queries(self):
        self.env["AEROSPACE_WINDOW_ID"] = "20"
        self.run_helper("cycle", "next", "top", "search", "hacking", "main", "other")
        self.assertEqual(self.state["focused"], "other-top")
        self.assertTrue(all(not context for context in self.state["contexts"]))

    def test_invalid_arguments_do_not_move_windows(self):
        self.run_helper("cycle", "wrong", "bottom", "main", success=False)
        self.assertEqual(self.state.get("calls", []), [])


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aerospace-render-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("aerospace-render.sh", "aerospace.template.toml"):
            shutil.copyfile(ROOT / name, self.root / name)
        self.output = self.root / "config with spaces & #.toml"

    def render(self):
        return subprocess.run(["/bin/bash", str(self.root / "aerospace-render.sh"), "--output", str(self.output)],
                              capture_output=True, text=True, timeout=10)

    def test_preview_needs_no_installed_helpers(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.output.read_text()
        self.assertIn('config-version = 2', content)
        self.assertIn('"other-bottom"', content)
        self.assertIn('"$HOME/.aerospace-ws.sh"', content)
        self.assertNotIn('__WS_', content)

    def test_unknown_placeholder_does_not_replace_output(self):
        self.output.write_text("existing config\n")
        template = self.root / "aerospace.template.toml"
        template.write_text(template.read_text() + '\n# __WS_UNKNOWN__\n')
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), "existing config\n")
        self.assertEqual(list(self.root.glob('*.tmp.*')), [])

    def test_duplicate_names_do_not_replace_output(self):
        self.output.write_text("existing config\n")
        script = self.root / "aerospace-render.sh"
        script.write_text(script.read_text().replace('WS_OTHER="other"', 'WS_OTHER="main"'))
        self.assertNotEqual(self.render().returncode, 0)
        self.assertEqual(self.output.read_text(), "existing config\n")


if __name__ == "__main__":
    unittest.main()
