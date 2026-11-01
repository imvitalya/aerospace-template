#!/usr/bin/env python3
"""Small stateful AeroSpace substitute; never connects to the window manager."""
import json
import fcntl
import os
import sys
from pathlib import Path

path = Path(os.environ["AEROSPACE_TEST_STATE"])
lock = path.with_suffix(".lock").open("a")
fcntl.flock(lock, fcntl.LOCK_EX)
state = json.loads(path.read_text())
args = sys.argv[1:]
cmd = args.pop(0)
state.setdefault("calls", []).append([cmd] + args)
state.setdefault("contexts", []).append({
    key: os.environ[key] for key in ("AEROSPACE_WINDOW_ID", "AEROSPACE_WORKSPACE")
    if key in os.environ
})


def finish(code=0, output=None):
    path.write_text(json.dumps(state))
    if output is not None:
        print(output)
    sys.exit(code)


def option(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default


def focused_workspace():
    window = os.environ.get("AEROSPACE_WINDOW_ID")
    if window in state["windows"]:
        return state["windows"][window]["workspace"]
    return os.environ.get("AEROSPACE_WORKSPACE", state["focused"])


def format_row(values, default):
    result = option("--format", default)
    for name, value in values.items():
        result = result.replace("%{" + name + "}", str(value))
    return result


if cmd in state.get("fail_commands", []):
    finish(1)

if cmd == "list-monitors":
    finish(output=1 if state["mode"] == "mac" else 3 if state["mode"] == "all" else 2)
elif cmd == "list-workspaces":
    if "--focused" in args:
        finish(output=focused_workspace())
    finish(output="\n".join(format_row({"workspace": ws, "monitor-id": monitor}, "%{workspace}")
                            for monitor, ws in state["visible"].items()))
elif cmd == "list-windows":
    windows = state["windows"]
    if "--focused" in args:
        window = state.get("focused_window")
        if window not in windows:
            finish(1)
        windows = {window: windows[window]}
    finish(output="\n".join(format_row({"window-id": window, "workspace": info["workspace"],
                                         "monitor-id": info["monitor"]}, "%{window-id}")
                            for window, info in windows.items()))
elif cmd == "workspace":
    direct = [arg for arg in args if arg != "--"]
    if "--stdin" in args:
        order = sys.stdin.read().split()
        current = focused_workspace()
        index = (order.index(current) + (1 if direct[0] == "next" else -1)) if current in order else 0
        target = order[index % len(order)]
    else:
        target = direct[0]
        if target == focused_workspace():
            finish()
    monitor = {"top": "1", "bottom": "2", "mac": "3"}.get(target.rsplit("-", 1)[-1], "1")
    if state["mode"] == "mac":
        monitor = "1"
    state["visible"][monitor] = target
    state["focused"] = target
    state["focused_window"] = next((key for key, info in state["windows"].items()
                                     if info["workspace"] == target), None)
    finish()
elif cmd == "move-node-to-workspace":
    window = option("--window-id", os.environ.get("AEROSPACE_WINDOW_ID", state.get("focused_window")))
    if window not in state["windows"] or window in state.get("fail_moves", []):
        finish(1)
    target = args[-1]
    state["windows"][window]["workspace"] = target
    if state.get("focused_window") == window:
        state["focused_window"] = next((key for key, info in state["windows"].items()
                                         if key != window and info["workspace"] == state["focused"]), None)
    finish()
else:
    finish(2)
