#!/bin/bash
# Генерирует ~/.aerospace.toml из ~/.aerospace.template.toml.
# Имена воркспейсов задаются здесь.
# После изменения запусти: ~/.aerospace-render.sh

set -euo pipefail

# Базовые имена воркспейсов. К каждому добавляется суффикс монитора:
# -top (верхний), -bottom (нижний), -mac (встроенный экран).
# Суффиксы зашиты в ~/.aerospace-ws.sh.
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

render_only=false
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 2 ] && [ "$1" = --output ]; then
        TARGET=$2
        render_only=true
    else
        echo "Использование: $0 [--output <файл>]" >&2
        exit 2
    fi
fi

for file in "$TEMPLATE"; do
    if [ ! -f "$file" ]; then
        echo "Файл не найден: $file" >&2
        exit 1
    fi
done

if ! "$render_only"; then
    [ -f "$WS_SCRIPT" ] || { echo "Файл не найден: $WS_SCRIPT" >&2; exit 1; }
    command -v aerospace >/dev/null || { echo "Не найден aerospace в PATH" >&2; exit 1; }
    loaded_config=$(aerospace config --config-path)
    case "$loaded_config" in
        "$TARGET"|*/AeroSpace.app/Contents/Resources/default-config.toml) ;;
        *)
            echo "AeroSpace использует $loaded_config, а генератор пишет $TARGET. Используйте --output для предпросмотра." >&2
            exit 1
            ;;
    esac
fi

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

tmp=$(mktemp "${TARGET}.tmp.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
sed \
    -e "s/__WS_INTERESTING__/$WS_INTERESTING/g" \
    -e "s/__WS_HACKING__/$WS_HACKING/g" \
    -e "s/__WS_MAIN__/$WS_MAIN/g" \
    -e "s/__WS_OTHER__/$WS_OTHER/g" \
    "$TEMPLATE" > "$tmp"

if grep -nE '__WS_[A-Z_]+__' "$tmp"; then
    echo "В шаблоне остались неизвестные плейсхолдеры" >&2
    exit 1
fi

if "$render_only"; then
    mv "$tmp" "$TARGET"
    echo "Сгенерирован $TARGET (без установки и перезагрузки)"
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
echo "  Воркспейсы: ${names[*]} (суффиксы -top, -bottom, -mac)"
[ -z "$backup" ] || echo "  Предыдущий конфиг: $backup"
