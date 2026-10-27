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

TEMPLATE="$HOME/.aerospace.template.toml"
TARGET="$HOME/.aerospace.toml"
WS_SCRIPT="$HOME/.aerospace-ws.sh"
INDICATOR_SRC="$HOME/.aerospace-indicator.swift"
INDICATOR_BIN="$HOME/.local/bin/aerospace-indicator"

for file in "$TEMPLATE" "$WS_SCRIPT" "$INDICATOR_SRC"; do
    if [ ! -f "$file" ]; then
        echo "Файл не найден: $file" >&2
        exit 1
    fi
done

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

sed \
    -e "s/__WS_SEARCH__/$WS_SEARCH/g" \
    -e "s/__WS_HACKING__/$WS_HACKING/g" \
    -e "s/__WS_MAIN__/$WS_MAIN/g" \
    -e "s/__WS_OTHER__/$WS_OTHER/g" \
    -e "s#__WS_SCRIPT__#$WS_SCRIPT#g" \
    -e "s#__WS_INDICATOR__#$INDICATOR_BIN#g" \
    "$TEMPLATE" > "$TARGET"

echo "Сгенерирован $TARGET:"
echo "  Воркспейсы: ${names[*]} (суффиксы -top, -bottom, -mac)"

# Индикатор для меню-бара пересобираем, только если исходник новее бинарника
if [ ! -x "$INDICATOR_BIN" ] || [ "$INDICATOR_SRC" -nt "$INDICATOR_BIN" ]; then
    mkdir -p "$(dirname "$INDICATOR_BIN")"
    swiftc -O -o "$INDICATOR_BIN" "$INDICATOR_SRC"
    echo "Собран $INDICATOR_BIN"
fi

if command -v aerospace >/dev/null 2>&1; then
    aerospace reload-config
    echo "AeroSpace конфиг перезагружен"

    # Новый экземпляр дождётся выхода старого: индикатор держит блокировку
    pkill -f "$INDICATOR_BIN" || true
    nohup "$INDICATOR_BIN" >/dev/null 2>&1 &
    echo "Индикатор перезапущен"
fi
