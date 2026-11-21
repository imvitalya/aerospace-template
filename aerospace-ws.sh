#!/bin/bash
# Сериализуем хоткеи, установку и callbacks тем же lockf, что и у предыдущей версии.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
dir=$(cd -- "$(dirname -- "$0")" && pwd)
prefix=${0##*/}
prefix=${prefix%%aerospace-ws.sh}
if [ "${1:-}" != layout ] && [ -z "${AEROSPACE_WS_LOCKED:-}" ]; then
    case "${1:-}" in
        move|adjacent|to-monitor)
            if [ -z "${AEROSPACE_WINDOW_ID:-}" ]; then
                unset AEROSPACE_WORKSPACE
                AEROSPACE_WINDOW_ID=$(aerospace list-windows --focused --format '%{window-id}')
                [ -n "$AEROSPACE_WINDOW_ID" ] || { echo "Нет активного окна для переноса" >&2; exit 1; }
                export AEROSPACE_WINDOW_ID
            fi
            ;;
    esac
    state="${XDG_STATE_HOME:-$HOME/.local/state}/aerospace"
    mkdir -p "$state"
    export AEROSPACE_WS_LOCKED=1
    exec lockf -k -s -t 15 "$state/lock" /bin/bash "$0" "$@"
fi
exec python3 "$dir/${prefix}aerospace-layout.py" "$@"
