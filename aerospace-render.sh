#!/bin/bash
# Генерирует ~/.aerospace.toml из ~/.aerospace.template.toml.
# Имена воркспейсов задаются здесь.
# После изменения запусти: ~/.aerospace-render.sh

set -euo pipefail

# Базовые имена воркспейсов. К каждому добавляется суффикс монитора:
# -top (верхний), -bottom (нижний), -mac (встроенный экран).
# Суффиксы зашиты в ~/.aerospace-ws.sh.
WS_SEARCH="search"
WS_HACKING="hacking"
WS_MAIN="main"
WS_OTHER="other"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ "$(basename -- "$0")" = .aerospace-render.sh ]; then
    TEMPLATE="$SCRIPT_DIR/.aerospace.template.toml"
    INDICATOR_SRC="$SCRIPT_DIR/.aerospace-indicator.swift"
else
    TEMPLATE="$SCRIPT_DIR/aerospace.template.toml"
    INDICATOR_SRC="$SCRIPT_DIR/aerospace-indicator.swift"
fi
TARGET="$HOME/.aerospace.toml"
WS_SCRIPT="$HOME/.aerospace-ws.sh"
INDICATOR_BIN="$HOME/.local/bin/aerospace-indicator"

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
    for file in "$WS_SCRIPT" "$INDICATOR_SRC"; do
        [ -f "$file" ] || { echo "Файл не найден: $file" >&2; exit 1; }
    done
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

names=("$WS_SEARCH" "$WS_HACKING" "$WS_MAIN" "$WS_OTHER")

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
binary_tmp=
trap 'rm -f -- "$tmp"; if [ -n "$binary_tmp" ]; then rm -f -- "$binary_tmp"; fi' EXIT
sed \
    -e "s/__WS_SEARCH__/$WS_SEARCH/g" \
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
    echo "Сгенерирован $TARGET (без установки, сборки и перезагрузки)"
    exit 0
fi

# Сначала готовим исполняемый файл. Ошибка компиляции не затронет рабочий конфиг.
if [ ! -x "$INDICATOR_BIN" ] || [ "$INDICATOR_SRC" -nt "$INDICATOR_BIN" ]; then
    mkdir -p "$(dirname "$INDICATOR_BIN")"
    binary_tmp=$(mktemp "${INDICATOR_BIN}.tmp.XXXXXX")
    swiftc -O -o "$binary_tmp" "$INDICATOR_SRC"
    mv "$binary_tmp" "$INDICATOR_BIN"
    binary_tmp=
    echo "Собран $INDICATOR_BIN"
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

# Неблокирующий lock индикатора не создаёт очередь ожидающих процессов.
# Дожидаемся освобождения старого экземпляра перед запуском нового.
pkill -x aerospace-indicator || true
for ((attempt=0; attempt<50; attempt++)); do
    pgrep -x aerospace-indicator >/dev/null || break
    sleep 0.1
done
if pgrep -x aerospace-indicator >/dev/null; then
    echo "Конфиг загружен, но старый индикатор не завершился за 5 секунд" >&2
    exit 1
fi
nohup "$INDICATOR_BIN" >/dev/null 2>&1 &
echo "Индикатор перезапущен"
