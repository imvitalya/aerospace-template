#!/bin/bash
# Генерирует ~/.aerospace.toml из ~/.aerospace.template.toml.
# Имена воркспейсов задаются здесь.
# После изменения запусти: ~/.aerospace-render.sh

set -euo pipefail

# Базовые имена четырех независимых групп.
WS_INTERESTING="interesting"
WS_HACKING="hacking"
WS_MAIN="main"
WS_OTHER="other"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ "$(basename -- "$0")" = .aerospace-render.sh ]; then
    TEMPLATE="$SCRIPT_DIR/.aerospace.template.toml"
else
    TEMPLATE="$SCRIPT_DIR/aerospace.template.toml"
fi
TARGET="$HOME/.aerospace.toml"
WS_SCRIPT="$HOME/.aerospace-ws.sh"

names=("$WS_INTERESTING" "$WS_HACKING" "$WS_MAIN" "$WS_OTHER")

# Имена попадают в sed и в аргументы помощника — без пробелов и спецсимволов
for name in "${names[@]}"; do
    if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Ошибка: недопустимое имя воркспейса '$name' (можно латиницу, цифры, - и _)" >&2
        exit 1
    fi
done

# Проверяем уникальность имён
for i in "${!names[@]}"; do
    for j in "${!names[@]}"; do
        if [ "$i" -lt "$j" ] && [ "${names[$i]}" = "${names[$j]}" ]; then
            echo "Ошибка: имена воркспейсов должны быть разными (повтор: ${names[$i]})" >&2
            exit 1
        fi
    done
done

# В одном внешнем режиме имя без суффикса должно оставаться однозначным.
for name in "${names[@]}"; do
    for other in "${names[@]}"; do
        for side in left right top bottom mac; do
            [ "$name" != "$other-$side" ] || { echo "Пересекаются имена '$name' и '$other'" >&2; exit 1; }
        done
    done
done
if [ "${1:-}" = --names ] && [ "$#" -eq 1 ]; then
    echo "${names[*]}"
    exit 0
fi

if [ "$#" -eq 0 ]; then
    exec /bin/bash "$WS_SCRIPT" sync --force
fi
layout='top=1 bottom=2 mac=3'
render_only=false
case "$1" in
    --output)
        [ "$#" -eq 2 ] || { [ "$#" -eq 4 ] && [ "$3" = --layout ]; } || exit 2
        render_only=true
        TARGET=$2
        layout=${4:-$layout}
        ;;
    --apply-layout)
        [ "$#" -eq 2 ] && [ -n "${AEROSPACE_WS_LOCKED:-}" ] || exit 2
        layout=$2
        loaded_config=$(aerospace config --config-path)
        case "$loaded_config" in
            "$TARGET"|*/AeroSpace.app/Contents/Resources/default-config.toml) ;;
            *) echo "AeroSpace использует $loaded_config вместо $TARGET" >&2; exit 1 ;;
        esac
        ;;
    *) echo "Использование: $0 [--output файл [--layout 'left=1 right=2']]" >&2; exit 2 ;;
esac
number='[1-9][0-9]*'
pattern="^(left=$number right=$number|top=$number bottom=$number|single=$number)( mac=$number)?$"
[[ "$layout" =~ $pattern || "$layout" =~ ^mac=$number$ ]] || { echo "Некорректная расстановка: $layout" >&2; exit 2; }

first_key=left second_key=right first_suffix=
case "$layout" in
    top=*) first_key=top; second_key=bottom; first_suffix=-top ;;
    left=*) first_suffix=-left ;;
    mac=*) first_suffix=-mac ;;
esac
persistent= assignments= seen=' '
for item in $layout; do
    side=${item%=*}
    monitor=${item#*=}
    [[ "$seen" != *" $monitor "* ]] || { echo "Повтор номера монитора $monitor" >&2; exit 2; }
    seen+="$monitor "
    for base in "${names[@]}"; do
        ws=$base
        [ "$side" = single ] || ws="$base-$side"
        [ "$side" = mac ] || persistent+="${persistent:+, }\"$ws\""
        assignments+="  \"$ws\" = $monitor"$'\n'
    done
done

tmp=$(mktemp "${TARGET}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
sed \
    -e "s/__WS_INTERESTING__/$WS_INTERESTING/g" \
    -e "s/__WS_HACKING__/$WS_HACKING/g" \
    -e "s/__WS_MAIN__/$WS_MAIN/g" \
    -e "s/__WS_OTHER__/$WS_OTHER/g" \
    -e "s/__WS_FIRST_KEY__/$first_key/g" \
    -e "s/__WS_SECOND_KEY__/$second_key/g" \
    -e "s/__WS_FIRST_SUFFIX__/$first_suffix/g" \
    -e "s/__WS_PERSISTENT__/$persistent/g" \
    "$TEMPLATE" | WS_ASSIGNMENTS="$assignments" awk '
        $0 == "__WS_ASSIGNMENTS__" { printf "%s", ENVIRON["WS_ASSIGNMENTS"]; next }
        { print }
    ' > "$tmp"

if grep -nE '__WS_[A-Z_]+__' "$tmp"; then
    echo "В шаблоне остались неизвестные плейсхолдеры" >&2
    exit 1
fi

if "$render_only"; then
    mv "$tmp" "$TARGET"
    echo "Сгенерирован $TARGET (без установки и перезагрузки)"
    exit 0
fi

if [ "$loaded_config" = "$TARGET" ] && [ -f "$TARGET" ] && cmp -s "$tmp" "$TARGET"; then
    exit 0
fi
backup=
if [ -e "$TARGET" ]; then
    backup=$(mktemp "${TARGET}.backup.XXXXXX")
    cp -p "$TARGET" "$backup"
fi
mv "$tmp" "$TARGET"
if ! aerospace reload-config --no-gui --warnings-as-errors; then
    if [ -n "$backup" ]; then
        cp -p "$backup" "$tmp"
        mv "$tmp" "$TARGET"
        aerospace reload-config --no-gui || true
    else
        rm -f -- "$TARGET"
    fi
    echo "Конфиг не принят AeroSpace; предыдущий файл восстановлен" >&2
    exit 1
fi
echo "Сгенерирован и загружен $TARGET"
echo "  Расстановка: $layout"
[ -z "$backup" ] || echo "  Предыдущий конфиг: $backup"
