"""Route AeroSpace workspaces using the display arrangement reported by macOS."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
PREFIX = "." if Path(__file__).name.startswith(".") else ""
RENDERER = HERE / (PREFIX + "aerospace-render.sh")
SCREENS = HERE / (PREFIX + "aerospace-screens.js")
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "aerospace"
ROLE = {"left": "first", "top": "first", "right": "second", "bottom": "second",
        "mac": "mac", "single": "first", "first": "first", "second": "second"}


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def aero(*args):
    return output("aerospace", *args)


def display_positions(displays, monitors):
    if len(displays) != len(monitors):
        raise ValueError("Меняется список экранов macOS")
    by_index = {m["monitor-appkit-nsscreen-screens-id"]: m for m in monitors}
    positions, external = {}, []
    for i, display in enumerate(displays, 1):
        m = by_index.get(i)
        if not m or m["monitor-name"] != display["name"]:
            raise ValueError("Меняется порядок экранов macOS")
        if display["mirror"]:
            continue
        if display["width"] <= 0 or display["height"] <= 0:
            raise ValueError("Размер экрана пока неизвестен")
        monitor = m["monitor-id"]
        if display["builtin"]:
            positions["mac"] = monitor
        else:
            external.append((display["x"] + display["width"] / 2, display["y"] + display["height"] / 2, monitor))
    if len(external) == 2:
        a, b = external
        horizontal = abs(b[0] - a[0]) >= abs(b[1] - a[1])
        order = sorted(external, key=lambda d: d[0] if horizontal else d[1])
        sides = ("left", "right") if horizontal else ("top", "bottom")
        positions.update(zip(sides, [d[2] for d in order]))
    elif len(external) == 1:
        positions["single"] = external[0][2]
    elif len(external) > 2:
        raise ValueError("Для этих двух групп клавиш поддерживаются до двух внешних мониторов")
    if not positions or len(set(positions.values())) != len(positions):
        raise ValueError("Не удалось однозначно сопоставить экраны с AeroSpace")
    return positions


def discover():
    fmt = "%{monitor-id} %{monitor-appkit-nsscreen-screens-id} %{monitor-name}"
    for attempt in range(3):
        before = json.loads(aero("list-monitors", "--format", fmt, "--json"))
        screens = json.loads(output("osascript", "-l", "JavaScript", str(SCREENS)))
        after = json.loads(aero("list-monitors", "--format", fmt, "--json"))
        try:
            if before != after:
                raise ValueError("Расстановка экранов меняется")
            return display_positions(screens, after)
        except ValueError:
            if attempt == 2:
                raise
            time.sleep(0.05)


def layout_option(layout):
    return " ".join(f"{side}={layout[side]}" for side in ("left", "right", "top", "bottom", "single", "mac") if side in layout)


def position(layout, role):
    if role == "mac" and "mac" in layout:
        return "mac"
    choices = ("right", "bottom") if role == "second" else ("left", "top")
    return next((s for s in (*choices, "single", "mac") if s in layout), None)


def ws_name(base, side):
    return base if side == "single" else f"{base}-{side}"


def split_name(ws, bases):
    if ws in bases:
        return ws, "single"
    base, _, side = ws.rpartition("-")
    if base in bases and side in ("left", "right", "top", "bottom", "mac"):
        return base, side
    return None, None


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def write_text(path, text):
    if path.exists() and path.read_text() == text:
        return
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def write_json(path, value):
    write_text(path, json.dumps(value, sort_keys=True) + "\n")


def list_windows():
    rows = aero("list-windows", "--all", "--format", "%{window-id}\t%{workspace}\t%{monitor-id}")
    return {wid: (ws, int(monitor)) for wid, ws, monitor in (s.split("\t") for s in rows.splitlines())}


def visible_workspaces():
    rows = aero("list-workspaces", "--monitor", "all", "--visible", "--format", "%{monitor-id}\t%{workspace}")
    return {int(monitor): ws for monitor, ws in (s.split("\t", 1) for s in rows.splitlines())}


def initial_roles(layout, bases):
    # Legacy top/bottom were pinned to 1/2. Capture their actual screens BEFORE reloading.
    rows = aero("list-workspaces", "--all", "--format", "%{workspace}\t%{monitor-id}")
    by_monitor = {monitor: ROLE[side] for side, monitor in layout.items()}
    result = {}
    for line in rows.splitlines():
        name, monitor = line.rsplit("\t", 1)
        _, side = split_name(name, bases)
        role = by_monitor.get(int(monitor))
        if side in ("top", "bottom") and role in ("first", "second"):
            result[side] = role
    if len(result) == 1 and ("right" in layout or "bottom" in layout):
        side, role = next(iter(result.items()))
        result["bottom" if side == "top" else "top"] = "second" if role == "first" else "first"
    return result if set(result.values()) == {"first", "second"} else {}


def remember_visible(layout, visible, bases):
    path = STATE / "visible.json"
    remembered = read_json(path)
    for side, monitor in layout.items():
        base, _ = split_name(visible[monitor], bases)
        if base:
            remembered[ROLE[side]] = base
    write_json(path, remembered)


def focused_window(windows, workspace):
    if not any(ws == workspace for ws, _ in windows.values()):
        return None
    result = subprocess.run(["aerospace", "list-windows", "--focused", "--format", "%{window-id}"],
                            capture_output=True, text=True)
    wid = result.stdout.strip()
    if result.returncode == 0 and wid in windows and windows[wid][0] == workspace:
        return wid
    return None


def sync(layout, bases, force=False):
    layout_file = STATE / "layout.json"
    journal = STATE / "transition.json"
    origins_file = STATE / "origins"
    previous, pending = read_json(layout_file), read_json(journal)
    changed = previous != layout or bool(pending)
    visible, windows = visible_workspaces(), list_windows()
    focus = aero("list-workspaces", "--focused")
    origins = dict(line.split() for line in origins_file.read_text().splitlines()) if origins_file.exists() else {}
    legacy = initial_roles(layout, bases) if not previous and not pending else {}
    default_base = bases[2]
    window_roles = {}
    destinations = {}
    next_origins = {}
    saved_roles = pending.get("windows", {})
    preferred = dict(pending.get("visible", {}))
    for ws in visible.values():
        base, side = split_name(ws, bases)
        if base:
            preferred.setdefault(legacy.get(side, ROLE[side]), base)
    for role, base in read_json(STATE / "visible.json").items():
        if base in bases:
            preferred.setdefault(role, base)
    focus_base, focus_side = split_name(focus, bases)
    focus_role = legacy.get(focus_side, ROLE.get(focus_side))
    if pending.get("focus") and changed:
        focus_base, focus_role = pending["focus"]
    default_base = focus_base or next(iter(preferred.values()), default_base)
    desired = {}
    for side, monitor in layout.items():
        base, old_side = split_name(visible.get(monitor, ""), bases)
        if changed:
            base = preferred.get(ROLE[side], base or default_base)
            if len(layout) == 1 and focus_base:
                base = focus_base
        desired[monitor] = ws_name(base or default_base, side)
    folded_side = "single" if "single" in previous else "mac"
    for wid, (ws, monitor) in windows.items():
        base, side = split_name(ws, bases)
        if not base:
            if ws.isdecimal() and monitor in desired:
                destinations[wid] = desired[monitor]
            continue
        role = legacy.get(side, ROLE[side])
        # Origins describe windows merged on the *previous* sole external or laptop.
        # An explicit transfer to the separately active Mac must stay on the Mac.
        if wid in origins and side == folded_side:
            role = legacy.get(origins[wid], ROLE[origins[wid]])
        if wid in saved_roles and ws in saved_roles[wid][:2]:
            role = saved_roles[wid][2]
        if role == "mac" and "mac" not in layout:
            role = "first"
        target_side = position(layout, role)
        target = ws_name(base, target_side)
        window_roles[wid] = [ws, target, role]
        if role != "mac" and target_side in ("single", "mac"):
            next_origins[wid] = role
        if ws != target:
            destinations[wid] = target
    focus_target = ws_name(focus_base, position(layout, focus_role)) if focus_base and focus_role else None
    if not focus_target:
        focused_monitor = next((m for m, ws in visible.items() if ws == focus), None)
        focus_target = desired.get(focused_monitor)
    needs_focus_check = changed or destinations or desired != visible
    focus_window = pending.get("focus_window")
    if needs_focus_check and not focus_window:
        focus_window = focused_window(windows, focus)
    if focus_window in windows:
        ws = destinations.get(focus_window, windows[focus_window][0])
        _, side = split_name(ws, bases)
        if side in layout:
            focus_target = desired[layout[side]] = ws
        else:
            focus_window = None
    if changed or destinations:
        write_json(journal, {"windows": window_roles, "visible": preferred,
                             "focus": [focus_base, focus_role] if focus_base else None,
                             "focus_window": focus_window})
    if changed or force:
        subprocess.run(["/bin/bash", str(RENDERER), "--apply-layout", layout_option(layout)], check=True)
    for wid, target in destinations.items():
        aero("move-node-to-workspace", "--window-id", wid, "--", target)
    if destinations:
        after = list_windows()
        if any(wid in after and after[wid][0] != target for wid, target in destinations.items()):
            raise ValueError("AeroSpace еще не применил перенос окон. Сохранен журнал для повтора")
        if focus_window not in after:
            focus_window = None
    actual = visible_workspaces() if changed or destinations or force else visible
    switched = False
    for monitor, ws in desired.items():
        if actual.get(monitor) != ws:
            aero("workspace", "--", ws)
            switched = True
    if focus_target and (switched or ((changed or destinations) and aero("list-workspaces", "--focused") != focus_target)):
        aero("workspace", "--", focus_target)
    if needs_focus_check and focus_window in windows:
        aero("focus", "--window-id", focus_window)
    write_text(origins_file, "".join(f"{wid} {role}\n" for wid, role in next_origins.items()))
    remember_visible(layout, desired, bases)
    write_json(layout_file, layout)
    journal.unlink(missing_ok=True)
    (STATE / "mode").unlink(missing_ok=True)
    return desired


def validate(args):
    cmd, *arg = args or [""]
    sides = ("left", "right", "top", "bottom", "mac")
    valid = ((cmd in ("focus", "move") and len(arg) == 2 and arg[1] in sides)
             or (cmd == "cycle" and len(arg) >= 3 and arg[0] in ("next", "prev") and arg[1] in sides)
             or (cmd == "to-monitor" and len(arg) == 1 and arg[0] in sides)
             or (cmd == "adjacent" and arg in (["next"], ["prev"]))
             or (cmd == "startup" and len(arg) == 1)
             or (cmd == "sync" and arg in ([], ["--force"]))
             or (cmd == "layout" and not arg))
    if not valid:
        raise ValueError("Неверные аргументы помощника AeroSpace")
    return cmd, arg


def main(args):
    cmd, arg = validate(args)
    requested = os.environ.pop("AEROSPACE_WINDOW_ID", None)
    os.environ.pop("AEROSPACE_WORKSPACE", None)
    if cmd in ("move", "to-monitor", "adjacent") and not requested:
        requested = aero("list-windows", "--focused", "--format", "%{window-id}")
        if not requested:
            raise ValueError("Нет активного окна для переноса")
    layout = discover()
    if cmd == "layout":
        print(layout_option(layout))
        return
    bases = output("/bin/bash", str(RENDERER), "--names").split()
    if (cmd in ("focus", "move", "startup") and arg[0] not in bases) or (cmd == "cycle" and any(b not in bases for b in arg[2:])):
        raise ValueError("Неизвестная база воркспейса")
    visible = sync(layout, bases, force=arg == ["--force"] or cmd == "startup")
    if cmd == "sync":
        return
    if cmd == "startup":
        side = position(layout, "first")
    elif cmd == "adjacent":
        if len(layout) < 2:
            return
        side = position(layout, "second" if arg[0] == "next" else "first")
        source = list_windows().get(requested)
        if "single" in layout and "mac" in layout:
            if source and source[1] == layout["single"]:
                side = "mac"
        if source and source[1] == layout[side]:
            return
    else:
        selector = arg[0] if cmd == "to-monitor" else arg[1]
        if selector == "mac" and cmd == "to-monitor" and "mac" not in layout:
            raise ValueError("Встроенный экран отключен")
        side = position(layout, ROLE[selector])
    if cmd in ("adjacent", "to-monitor"):
        target = visible[layout[side]]
    elif cmd == "cycle":
        choices = [ws_name(base, side) for base in arg[2:]]
        current = visible[layout[side]]
        index = choices.index(current) + (1 if arg[0] == "next" else -1) if current in choices else 0
        target = choices[index % len(choices)]
    else:
        target = ws_name(arg[0], side)
    if cmd in ("move", "to-monitor", "adjacent"):
        aero("move-node-to-workspace", "--window-id", requested, "--", target)
    else:
        aero("workspace", "--", target)
        visible[layout[side]] = target
        remember_visible(layout, visible, bases)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
