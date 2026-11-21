#!/usr/bin/env python3
"""Stateful, isolated substitutes for the AeroSpace CLI and the macOS screen reader."""
import fcntl
import json
import os
import re
import sys
from pathlib import Path

path = Path(os.environ["AEROSPACE_TEST_STATE"])
lock = path.with_suffix(".lock").open("a")
fcntl.flock(lock, fcntl.LOCK_EX)
state = json.loads(path.read_text())
mode = state["mode"]
arrangements = {
    "ext": [(0, -1440, False), (0, 0, False)],
    "horizontal": [(0, 0, False), (2560, 0, False)],
    "mac": [(0, 0, True)],
    "one": [(0, 0, False)],
    "all": [(0, -1440, False), (0, 0, False), (2560, 0, True)],
}
screens = [dict(x=x, y=y, width=2560, height=1440, builtin=b, name="Display", mirror=False)
           for x, y, b in state.get("screens", arrangements[mode])]
if Path(sys.argv[0]).name == "osascript":
    print(json.dumps(screens))
    sys.exit(0)

args = sys.argv[1:]
cmd = args.pop(0)
state.setdefault("calls", []).append([cmd] + args)
state.setdefault("contexts", []).append({k: os.environ[k] for k in ("AEROSPACE_WORKSPACE", "AEROSPACE_WINDOW_ID") if k in os.environ})


def finish(code=0, output=None):
    path.write_text(json.dumps(state))
    if output is not None:
        print(output)
    sys.exit(code)


def option(key, default=None):
    return args[args.index(key) + 1] if key in args else default


def fmt(values, default):
    result = option("--format", default)
    for k, value in values.items():
        result = result.replace("%{" + k + "}", str(value))
    return result


def monitor_of(ws, fallback):
    return str(state.get("pins", {}).get(ws, fallback))


if cmd in state.get("fail_commands", []):
    finish(1)
if cmd == "config":
    finish(output=Path.home() / ".aerospace.toml")
if cmd == "reload-config":
    content = (Path.home() / ".aerospace.toml").read_text()
    state["pins"] = dict(re.findall(r'^\s*"([^"]+)" = (\d+)$', content, re.M))
    finish()
if cmd == "list-monitors":
    order = sorted(range(len(screens)), key=lambda i: (screens[i]["x"], screens[i]["y"]))
    finish(output=json.dumps([{"monitor-id": n, "monitor-appkit-nsscreen-screens-id": i + 1, "monitor-name": "Display"}
                              for n, i in enumerate(order, 1)]))
if cmd == "list-workspaces":
    if "--focused" in args:
        finish(output=state["focused"])
    workspaces = {ws: monitor for monitor, ws in state["visible"].items()}
    if "--all" in args:
        for window in state["windows"].values():
            workspaces.setdefault(window["workspace"], window["monitor"])
        workspaces.update(state.get("pins", {}))
    finish(output="\n".join(fmt({"workspace": ws, "monitor-id": m}, "%{workspace}") for ws, m in workspaces.items()))
if cmd == "list-windows":
    windows = state["windows"]
    if "--focused" in args:
        wid = state.get("focused_window")
        if wid not in windows:
            finish(1)
        windows = {wid: windows[wid]}
    finish(output="\n".join(fmt({"window-id": wid, "workspace": win["workspace"],
                                 "monitor-id": monitor_of(win["workspace"], win["monitor"])}, "%{window-id}")
                            for wid, win in windows.items()))
if cmd == "workspace":
    ws = args[-1]
    monitor = monitor_of(ws, state["windows"].get(state.get("focused_window"), {}).get("monitor", "1"))
    state["visible"][monitor] = ws
    state["focused"] = ws
    state["focused_window"] = next((wid for wid, win in state["windows"].items() if win["workspace"] == ws), None)
    finish()
if cmd == "focus" and "--window-id" in args:
    wid = option("--window-id")
    win = state["windows"][wid]
    state.update(focused=win["workspace"], focused_window=wid)
    state["visible"][win["monitor"]] = win["workspace"]
    finish()
if cmd == "move-node-to-workspace":
    wid = option("--window-id")
    if wid not in state["windows"] or wid in state.get("fail_moves", []):
        finish(1)
    if wid in state.get("ignore_moves", []):
        finish()
    win = state["windows"][wid]
    ws = args[-1]
    win.update(workspace=ws, monitor=monitor_of(ws, win["monitor"]))
    if state.get("focused_window") == wid and state["focused"] != ws:
        state["focused_window"] = next((i for i, other in state["windows"].items() if other["workspace"] == state["focused"]), None)
    finish()
finish(2)
