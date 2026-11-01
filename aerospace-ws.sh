#!/bin/bash
# Помощник для ~/.aerospace.toml: переключает воркспейсы с учётом того,
# какие мониторы сейчас подключены. Вызывается из хоткеев AeroSpace.
#
# Полное имя воркспейса — база и суффикс монитора:
#   <база>-top     верхний внешний монитор
#   <база>-bottom  нижний внешний монитор
#   <база>-mac     встроенный экран MacBook
#
# Режим определяется по крышке и числу мониторов:
#   ext  крышка закрыта, работают только внешние мониторы;
#   mac  крышка открыта, внешних мониторов нет: окна из <база>-top
#        и <база>-bottom «схлопываются» в <база>-mac;
#   all  крышка открыта и внешние мониторы подключены.
# После выхода из mac окна возвращаются на свой монитор. Окна, открытые
# на ноутбуке, в режиме ext переезжают в <база>-top.
#
# В режиме ext помощник при каждом вызове следит, чтобы на мониторе 1 был
# виден *-top, а на мониторе 2 — *-bottom: AeroSpace сам может показать там
# чужой воркспейс, например временный «1». Окна из воркспейсов вне схемы
# переезжают на видимый воркспейс своего монитора.
#
# Команды:
#   focus <база> top|bottom               перейти на воркспейс
#   move <база> top|bottom                перенести туда активное окно
#   cycle next|prev top|bottom <база>...  листать воркспейсы по кругу
#   to-monitor mac|top|bottom             перенести активное окно на монитор
#   sync [--force]                        разложить окна под текущий режим
#   startup <база>                        sync --force и переход на <база>

set -euo pipefail

# В окружении AeroSpace PATH может не содержать Homebrew
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/aerospace"
MODE_FILE="$STATE_DIR/mode"
# Строки "<window-id> top|bottom": откуда пришли схлопнутые в *-mac окна
ORIGINS_FILE="$STATE_DIR/origins"

mkdir -p "$STATE_DIR"

# Хоткеи и события срабатывают почти одновременно — выполняем их по очереди
if [ -z "${AEROSPACE_WS_LOCKED:-}" ]; then
    export AEROSPACE_WS_LOCKED=1
    exec lockf -k -s -t 5 "$STATE_DIR/lock" /bin/bash "$0" "$@"
fi

# Контекст callback относится к окну в момент события. Для синхронизации
# и цикла нужен текущий глобальный фокус; перенос сохраняет исходное окно явно.
requested_window=${AEROSPACE_WINDOW_ID:-}
unset AEROSPACE_WINDOW_ID AEROSPACE_WORKSPACE

lid_closed() {
    ioreg -r -k AppleClamshellState -d 1 | grep '"AppleClamshellState" = Yes' >/dev/null
}

detect_mode() {
    local count
    count=$(aerospace list-monitors --count) || return 1
    if lid_closed; then
        echo ext
    elif [ "$count" -le 1 ]; then
        echo mac
    else
        echo all
    fi
}

windows() {
    aerospace list-windows --all --format '%{window-id} %{workspace}'
}

# Окна из *-top и *-bottom переезжают в *-mac, их позиция запоминается
collapse() {
    local snapshot id ws
    snapshot=$(windows) || return 1
    while read -r id ws; do
        case "$ws" in
            *-top | *-bottom)
                # Записываем назначение до переноса: при обрыве команды его
                # можно повторить, а исходный монитор не потеряется.
                touch "$ORIGINS_FILE"
                awk -v id="$id" '$1 != id' "$ORIGINS_FILE" > "$ORIGINS_FILE.tmp"
                echo "$id ${ws##*-}" >> "$ORIGINS_FILE.tmp"
                mv "$ORIGINS_FILE.tmp" "$ORIGINS_FILE"
                aerospace move-node-to-workspace --window-id "$id" -- "${ws%-*}-mac" || return 1
                ;;
        esac
    done <<< "$snapshot"
}

# Схлопнутые окна возвращаются на свою позицию, но в текущую базу:
# окно, перенесённое на ноутбуке из main-mac в other-mac, уедет в other-top/-bottom
restore() {
    local snapshot moves id ws failed=0
    [ -s "$ORIGINS_FILE" ] || return 0
    snapshot=$(windows) || return 1
    moves=$(awk 'NR == FNR { pos[$1] = $2; next }
                 ($1 in pos) && sub(/-mac$/, "", $2) { print $1, $2 "-" pos[$1] }' \
        "$ORIGINS_FILE" - <<< "$snapshot") || return 1
    while read -r id ws; do
        [ -n "$id" ] || continue
        aerospace move-node-to-workspace --window-id "$id" -- "$ws" || failed=1
    done <<< "$moves"
    # Успешно перенесённые окна при повторе уже не попадут в выборку *-mac.
    # При ошибке сохраняем журнал и прежний режим, чтобы следующий sync повторил перенос.
    [ "$failed" -eq 0 ] || return 1
    : > "$ORIGINS_FILE"
}

# Без встроенного экрана *-mac не нужны: оставшиеся там окна уезжают в *-top
drain_mac() {
    local snapshot id ws
    snapshot=$(windows) || return 1
    while read -r id ws; do
        case "$ws" in
            *-mac) aerospace move-node-to-workspace --window-id "$id" -- "${ws%-mac}-top" || return 1 ;;
        esac
    done <<< "$snapshot"
}

# Номер монитора в AeroSpace → суффикс, как в workspace-to-monitor-force-assignment
monitor_suffix() {
    case "$1" in
        1) echo top ;;
        2) echo bottom ;;
    esac
}

# Без встроенного экрана на каждом мониторе должен быть виден воркспейс
# с его суффиксом. Возвращает 0, если что-то пришлось переключить
fix_visible() {
    local visible focused new_focus= base= changed= ws monitor suffix target
    visible=$(aerospace list-workspaces --monitor all --visible --format '%{workspace} %{monitor-id}') || return 2
    # Базу для временного воркспейса вроде «1» берём у соседнего монитора
    while read -r ws monitor; do
        case "$ws" in
            *-top | *-bottom | *-mac)
                base=${ws%-*}
                break
                ;;
        esac
    done <<< "$visible"
    focused=$(aerospace list-workspaces --focused) || return 2
    while read -r ws monitor; do
        suffix=$(monitor_suffix "$monitor")
        [ -n "$suffix" ] || continue
        case "$ws" in
            *-"$suffix") continue ;;
            *-top | *-bottom | *-mac) target="${ws%-*}-$suffix" ;;
            *)
                [ -n "$base" ] || continue
                target="$base-$suffix"
                ;;
        esac
        aerospace workspace -- "$target" || return 2
        [ "$ws" = "$focused" ] && new_focus=$target
        changed=1
    done <<< "$visible"
    [ -n "$changed" ] || return 1
    aerospace workspace -- "${new_focus:-$focused}" || return 2
}

# Окна из воркспейсов вне схемы (например, временного «1») переезжают
# на воркспейс, который сейчас виден на их мониторе
adopt_strays() {
    local visible snapshot moves id ws
    visible=$(aerospace list-workspaces --monitor all --visible --format '%{workspace} %{monitor-id}') || return 1
    snapshot=$(aerospace list-windows --all --format '%{window-id} %{workspace} %{monitor-id}') || return 1
    [ -n "$visible" ] || return 0
    moves=$(awk 'NR == FNR { target[$2] = $1; next }
             $2 !~ /-(top|bottom|mac)$/ && ($3 in target) { print $1, target[$3] }' \
        <(printf '%s\n' "$visible") - <<< "$snapshot") || return 1
    while read -r id ws; do
        [ -n "$id" ] || continue
        aerospace move-node-to-workspace --window-id "$id" -- "$ws" || return 1
    done <<< "$moves"
}

# *-mac не постоянные, поэтому при открытии крышки AeroSpace показывает
# на ноутбуке временный воркспейс — заменяем его на <база>-mac
show_mac_on_builtin() {
    local focused visible ws
    visible=$(aerospace list-workspaces --monitor all --visible)
    while IFS= read -r ws; do
        case "$ws" in *-mac) return 0 ;; esac
    done <<< "$visible"
    focused=$(aerospace list-workspaces --focused)
    case "$focused" in
        *-top | *-bottom)
            aerospace workspace -- "${focused%-*}-mac"
            aerospace workspace -- "$focused"
            ;;
    esac
}

show_mac_workspace() {
    local focused
    focused=$(aerospace list-workspaces --focused)
    case "$focused" in
        *-top | *-bottom) aerospace workspace -- "${focused%-*}-mac" ;;
    esac
}

MODE=

sync_mode() {
    local last changed= visible_status
    MODE=$(detect_mode) || exit 1
    last=$(cat "$MODE_FILE" 2>/dev/null || true)
    if [ "$MODE" != "$last" ] || [ "${1:-}" = --force ]; then
        changed=1
    fi

    case "$MODE" in
        mac)
            # Схлопываем при каждом вызове: окно могло попасть в *-top/*-bottom
            # правилом on-window-detected
            collapse
            show_mac_workspace
            ;;
        all)
            restore
            if [ -n "$changed" ]; then
                show_mac_on_builtin
            fi
            ;;
        ext)
            restore
            drain_mac
            # AeroSpace мог сам показать не тот воркспейс — проверяем при каждом вызове
            visible_status=0
            fix_visible || visible_status=$?
            [ "$visible_status" -le 1 ] || return 1
            if [ "$visible_status" -eq 0 ] || [ -n "$changed" ]; then
                adopt_strays
            fi
            ;;
    esac
    echo "$MODE" > "$MODE_FILE.tmp"
    mv "$MODE_FILE.tmp" "$MODE_FILE"
}

# Цикл отсчитывается от видимого воркспейса нужного монитора, даже если
# сейчас фокус на другом. workspace next/prev --stdin иначе выбирает первый пункт.
cycle() {
    local dir=$1 pos=$2 visible current= base ws index=0 i
    shift 2
    local order=()
    visible=$(aerospace list-workspaces --monitor all --visible)
    for base in "$@"; do
        ws=$(target "$base" "$pos")
        order+=("$ws")
        while IFS= read -r current; do
            if [ "$current" = "$ws" ]; then
                index=${#order[@]}
            fi
        done <<< "$visible"
    done
    [ "${#order[@]}" -gt 0 ] || return 2
    if [ "$index" -eq 0 ]; then
        i=0
    elif [ "$dir" = next ]; then
        i=$((index % ${#order[@]}))
    else
        i=$(((index + ${#order[@]} - 2) % ${#order[@]}))
    fi
    aerospace workspace -- "${order[$i]}"
}

# <база> top|bottom → имя воркспейса; без внешних мониторов всё ведёт в *-mac
target() {
    if [ "$MODE" = mac ]; then
        echo "$1-mac"
    else
        echo "$1-$2"
    fi
}

cmd=${1:-}
[ -n "$cmd" ] || { echo "Укажите команду (focus, move, cycle, to-monitor, sync, startup)" >&2; exit 2; }
shift

# Проверка аргументов до любых перемещений окон.
case "$cmd" in
    focus|move) [ "$#" -eq 2 ] && [[ "$2" =~ ^(top|bottom|mac)$ ]] ;;
    cycle) [ "$#" -ge 3 ] && [[ "$1" =~ ^(next|prev)$ ]] && [[ "$2" =~ ^(top|bottom|mac)$ ]] ;;
    to-monitor) [ "$#" -eq 1 ] && [[ "$1" =~ ^(top|bottom|mac)$ ]] ;;
    sync) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --force ]; } ;;
    startup) [ "$#" -eq 1 ] ;;
    *) false ;;
esac || { echo "Неверные аргументы команды '$cmd'. См. начало $0" >&2; exit 2; }

if [ "$cmd" = move ] || [ "$cmd" = to-monitor ]; then
    requested_window=${requested_window:-$(aerospace list-windows --focused --format '%{window-id}')}
    [ -n "$requested_window" ] || { echo "Нет активного окна для переноса" >&2; exit 1; }
fi

case "$cmd" in
    focus)
        sync_mode
        aerospace workspace -- "$(target "$1" "$2")"
        ;;
    move)
        sync_mode
        aerospace move-node-to-workspace --window-id "$requested_window" -- "$(target "$1" "$2")"
        ;;
    cycle)
        sync_mode
        cycle "$@"
        ;;
    to-monitor)
        sync_mode
        visible=$(aerospace list-workspaces --monitor all --visible)
        ws=$(printf '%s\n' "$visible" | awk -v suffix="-$1" '$0 ~ (suffix "$") { print; exit }')
        [ -n "$ws" ] || { echo "Нет видимого воркспейса для монитора '$1'" >&2; exit 1; }
        aerospace move-node-to-workspace --window-id "$requested_window" -- "$ws"
        ;;
    sync)
        sync_mode "${1:-}"
        ;;
    startup)
        sync_mode --force
        aerospace workspace -- "$(target "$1" top)"
        ;;
    *)
        echo "Неизвестная команда '$cmd'. Список команд — в начале $0" >&2
        exit 2
        ;;
esac
