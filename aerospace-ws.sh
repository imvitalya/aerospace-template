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

# В окружении AeroSpace PATH может не содержать Homebrew
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/aerospace"
MODE_FILE="$STATE_DIR/mode"
# Строки "<window-id> top|bottom": откуда пришли схлопнутые в *-mac окна
ORIGINS_FILE="$STATE_DIR/origins"

mkdir -p "$STATE_DIR"

# Хоткеи и события срабатывают почти одновременно — выполняем их по очереди
if [ -z "$AEROSPACE_WS_LOCKED" ]; then
    export AEROSPACE_WS_LOCKED=1
    exec lockf -k -s -t 5 "$STATE_DIR/lock" /bin/bash "$0" "$@"
fi

lid_closed() {
    ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'
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
    windows | while read -r id ws; do
        case "$ws" in
            *-top | *-bottom)
                aerospace move-node-to-workspace --window-id "$id" "${ws%-*}-mac" &&
                    echo "$id ${ws##*-}" >> "$ORIGINS_FILE"
                ;;
        esac
    done
}

# Схлопнутые окна возвращаются на свою позицию, но в текущую базу:
# окно, перенесённое на ноутбуке из main-mac в other-mac, уедет в other-top/-bottom
restore() {
    [ -s "$ORIGINS_FILE" ] || return 0
    windows |
        awk 'NR == FNR { pos[$1] = $2; next }
             ($1 in pos) && sub(/-mac$/, "", $2) { print $1, $2 "-" pos[$1] }' "$ORIGINS_FILE" - |
        while read -r id ws; do
            aerospace move-node-to-workspace --window-id "$id" "$ws"
        done
    : > "$ORIGINS_FILE"
}

# Без встроенного экрана *-mac не нужны: оставшиеся там окна уезжают в *-top
drain_mac() {
    windows | while read -r id ws; do
        case "$ws" in
            *-mac) aerospace move-node-to-workspace --window-id "$id" "${ws%-mac}-top" ;;
        esac
    done
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
    visible=$(aerospace list-workspaces --monitor all --visible --format '%{workspace} %{monitor-id}')
    # Базу для временного воркспейса вроде «1» берём у соседнего монитора
    while read -r ws monitor; do
        case "$ws" in
            *-top | *-bottom | *-mac)
                base=${ws%-*}
                break
                ;;
        esac
    done <<< "$visible"
    focused=$(aerospace list-workspaces --focused)
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
        aerospace workspace "$target"
        [ "$ws" = "$focused" ] && new_focus=$target
        changed=1
    done <<< "$visible"
    [ -n "$changed" ] || return 1
    aerospace workspace "${new_focus:-$focused}"
}

# Окна из воркспейсов вне схемы (например, временного «1») переезжают
# на воркспейс, который сейчас виден на их мониторе
adopt_strays() {
    aerospace list-windows --all --format '%{window-id} %{workspace} %{monitor-id}' |
        awk 'NR == FNR { target[$2] = $1; next }
             $2 !~ /-(top|bottom|mac)$/ && ($3 in target) { print $1, target[$3] }' \
            <(aerospace list-workspaces --monitor all --visible --format '%{workspace} %{monitor-id}') - |
        while read -r id ws; do
            aerospace move-node-to-workspace --window-id "$id" "$ws"
        done
}

# *-mac не постоянные, поэтому при открытии крышки AeroSpace показывает
# на ноутбуке временный воркспейс — заменяем его на <база>-mac
show_mac_on_builtin() {
    local focused
    aerospace list-workspaces --monitor all --visible | grep -q -- '-mac$' && return 0
    focused=$(aerospace list-workspaces --focused)
    case "$focused" in
        *-top | *-bottom)
            aerospace workspace "${focused%-*}-mac"
            aerospace workspace "$focused"
            ;;
    esac
}

show_mac_workspace() {
    local focused
    focused=$(aerospace list-workspaces --focused)
    case "$focused" in
        *-top | *-bottom) aerospace workspace "${focused%-*}-mac" ;;
    esac
}

MODE=

sync_mode() {
    local last changed=
    MODE=$(detect_mode) || exit 1
    last=$(cat "$MODE_FILE" 2>/dev/null)
    if [ "$MODE" != "$last" ] || [ "$1" = --force ]; then
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
            if [ -n "$changed" ]; then
                restore
                show_mac_on_builtin
            fi
            ;;
        ext)
            if [ -n "$changed" ]; then
                restore
                drain_mac
            fi
            # AeroSpace мог сам показать не тот воркспейс — проверяем при каждом вызове
            if fix_visible || [ -n "$changed" ]; then
                adopt_strays
            fi
            ;;
    esac
    echo "$MODE" > "$MODE_FILE"
}

# <база> top|bottom → имя воркспейса; без внешних мониторов всё ведёт в *-mac
target() {
    if [ "$MODE" = mac ]; then
        echo "$1-mac"
    else
        echo "$1-$2"
    fi
}

cmd=$1
shift

case "$cmd" in
    focus)
        sync_mode
        aerospace workspace "$(target "$1" "$2")"
        ;;
    move)
        sync_mode
        aerospace move-node-to-workspace "$(target "$1" "$2")"
        ;;
    cycle)
        sync_mode
        dir=$1 pos=$2
        shift 2
        for base in "$@"; do
            target "$base" "$pos"
        done | aerospace workspace "$dir" --stdin --wrap-around
        ;;
    to-monitor)
        sync_mode
        ws=$(aerospace list-workspaces --monitor all --visible | grep -- "-$1\$" | head -n 1)
        [ -n "$ws" ] && aerospace move-node-to-workspace "$ws"
        ;;
    sync)
        sync_mode "$1"
        ;;
    startup)
        sync_mode --force
        aerospace workspace "$(target "$1" top)"
        ;;
    *)
        echo "Неизвестная команда '$cmd'. Список команд — в начале $0" >&2
        exit 2
        ;;
esac
