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


INSTALL_FILES = ["aerospace-ws.sh","aerospace-layout.py","aerospace-screens.js","aerospace-render.sh","aerospace.template.toml"]


def fake_tools(root):
    for name in ("aerospace", "osascript"):
        binary = root / name
        shutil.copyfile(ROOT / "tests/fake_aerospace.py", binary)
        binary.chmod(0o755)


def install_sources(home):
    for name in INSTALL_FILES:
        shutil.copyfile(ROOT / name, home / ("." + name))


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aerospace-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        fake_tools(self.root)
        home = self.root / "home"
        home.mkdir()
        install_sources(home)
        self.state_file = self.root / "server.json"
        self.state_dir = self.root / "state/aerospace"
        self.state_dir.mkdir(parents=True)
        self.mode_file = self.state_dir / "mode"
        self.origins = self.state_dir / "origins"
        self.env = dict(os.environ, HOME=str(home), PATH=str(self.root) + ":/usr/bin:/bin",
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
        self.run_helper("cycle", "next", "bottom", "interesting", "hacking", "main", "other")
        self.assertEqual(self.state["focused"], "main-bottom")

    def test_cycle_previous_wraps_on_target_monitor(self):
        self.state["visible"]["2"] = "interesting-bottom"
        self.run_helper("cycle", "prev", "bottom", "interesting", "hacking", "main", "other")
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
        self.run_helper("cycle", "next", "top", "interesting", "hacking", "main", "other")
        self.assertEqual(self.state["focused"], "other-top")
        self.assertTrue(all(not context for context in self.state["contexts"]))

    def test_invalid_arguments_do_not_move_windows(self):
        self.run_helper("cycle", "wrong", "bottom", "main", success=False)
        self.assertEqual(self.state.get("calls", []), [])

    def test_rotate_and_use_old_binding_without_losing_windows_or_neighbor(self):
        self.state["mode"] = "horizontal"
        self.run_helper("focus", "interesting", "bottom")
        self.assertEqual(self.state["visible"], {"1": "main-left", "2": "interesting-right"})
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-left")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-right")
        self.state["mode"] = "ext"
        self.run_helper("focus", "interesting", "right")
        self.assertEqual(self.state["visible"], {"1": "main-top", "2": "interesting-bottom"})
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-bottom")
        reloads = self.state["calls"].count(["reload-config", "--no-gui", "--warnings-as-errors"])
        self.run_helper("sync")
        self.assertEqual(self.state["calls"].count(["reload-config", "--no-gui", "--warnings-as-errors"]), reloads)

    def test_single_external_and_laptop_remember_second_window(self):
        self.state["mode"] = "horizontal"
        self.run_helper("sync")
        self.state.update(mode="one", visible={"1": "main-left"})
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking")
        self.run_helper("focus", "main", "right")
        self.assertEqual(self.state["focused"], "main")
        self.state.update(mode="mac", visible={"1": "main"}, focused="main")
        self.run_helper("sync")
        self.state["windows"]["20"]["workspace"] = "other-mac"
        self.state.update(mode="horizontal", visible={"1": "main-mac", "2": "1"})
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "other-right")

    def test_migration_resumes_across_another_rotation(self):
        self.state["mode"] = "horizontal"
        self.state["fail_moves"] = ["20"]
        self.run_helper("sync", success=False)
        self.assertTrue((self.state_dir / "transition.json").exists())
        self.state["fail_moves"] = []
        self.state["mode"] = "ext"
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-top")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-bottom")
        self.assertFalse((self.state_dir / "transition.json").exists())

    def test_initial_swap_uses_actual_screen_and_retries_only_remaining_window(self):
        self.state["screens"] = [(100, -1440, False), (0, 0, False)]
        self.state["fail_moves"] = ["20"]
        self.run_helper("sync", success=False)
        self.state["fail_moves"] = []
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-bottom")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-top")

    def test_adjacent_moves_to_visible_workspace_of_other_external(self):
        self.state["mode"] = "horizontal"
        self.run_helper("adjacent", "next")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "hacking-right")

    def test_sync_preserves_the_specific_focused_window(self):
        self.state["mode"] = "horizontal"
        self.state["windows"]["11"] = {"workspace": "main-top", "monitor": "1"}
        self.state["focused_window"] = "11"
        self.run_helper("sync")
        self.assertEqual(self.state["focused_window"], "11")

    def test_move_reported_as_success_but_not_applied_keeps_journal(self):
        self.state.update(mode="horizontal", ignore_moves=["20"])
        self.run_helper("sync", success=False)
        self.assertTrue((self.state_dir / "transition.json").is_file())
        self.state["ignore_moves"] = []
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-right")

    def test_folded_window_can_be_sent_to_builtin_while_external_is_connected(self):
        self.state.update(screens=[(0, 0, False), (2560, 0, True)],
                          visible={"1": "main", "2": "other-mac"}, focused="main")
        self.state["windows"]["10"].update(workspace="main", monitor="1")
        self.run_helper("sync")
        self.env["AEROSPACE_WINDOW_ID"] = "10"
        self.run_helper("to-monitor", "mac")
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "other-mac")

    def test_first_install_matches_external_even_when_old_top_was_on_mac(self):
        self.state.update(screens=[(-2560, 0, True), (0, 0, False), (2560, 0, False)],
                          visible={"1": "main-top", "2": "hacking-bottom", "3": "1"})
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["20"]["workspace"], "hacking-left")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-right")

    def test_legacy_laptop_origin_uses_actual_monitor_of_old_workspace(self):
        self.state["screens"] = [(100, -1440, False), (0, 0, False)]
        self.state["pins"] = {"main-top": "1", "main-bottom": "2"}
        self.state["windows"]["10"]["workspace"] = "main-mac"
        self.origins.write_text("10 bottom\n")
        self.run_helper("sync")
        self.assertEqual(self.state["windows"]["10"]["workspace"], "main-top")

    def test_restore_visible_bases_when_aerospace_temporarily_shows_numeric_workspaces(self):
        self.state["mode"] = "horizontal"
        self.run_helper("focus", "other", "right")
        self.state.update(mode="ext", visible={"1": "1", "2": "2"}, focused="1", focused_window=None)
        self.run_helper("sync")
        self.assertEqual(self.state["visible"], {"1": "main-top", "2": "other-bottom"})


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
        self.assertIn('"interesting-top"', content)
        self.assertIn('"interesting-bottom"', content)
        self.assertIn('"interesting-mac"', content)
        self.assertIn('"other-bottom"', content)
        self.assertIn('"$HOME/.aerospace-ws.sh"', content)
        self.assertIn('focus interesting top', content)
        self.assertIn('move interesting bottom', content)
        self.assertNotIn('aerospace-indicator', content)
        self.assertNotIn('__WS_', content)

    def test_install_without_indicator_reloads_and_keeps_backup(self):
        home = self.root / "home with spaces"
        home.mkdir()
        install_sources(home)
        target = home / ".aerospace.toml"
        target.write_text("previous config\n")
        fake_tools(self.root)
        state = self.root / "aerospace.json"
        state.write_text(json.dumps({"mode": "horizontal", "visible": {"1": "main-top", "2": "main-bottom"},
                                     "focused": "main-top", "windows": {}}))
        env = dict(os.environ, HOME=str(home), PATH=str(self.root) + ":/usr/bin:/bin",
                   XDG_STATE_HOME=str(home / ".state"), AEROSPACE_TEST_STATE=str(state))
        result = subprocess.run(["/bin/bash", str(home / ".aerospace-render.sh")],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["reload-config", "--no-gui", "--warnings-as-errors"], json.loads(state.read_text())["calls"])
        self.assertIn('"interesting-left"', target.read_text())
        backups = list(home.glob(".aerospace.toml.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "previous config\n")
        self.assertEqual(list(home.glob(".aerospace.toml.tmp.*")), [])

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
