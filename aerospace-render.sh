#!/bin/bash
# Генерирует ~/.aerospace.toml из ~/.aerospace.template.toml, подставляя имена
# воркспейсов из переменных ниже. Чтобы переименовать воркспейс — поменяй значение
# здесь и запусти этот скрипт: ~/.aerospace-render.sh
#
# Физическая клавиша (ctrl-s/h/m/o и т.п.) при этом НЕ меняется — она задана в шаблоне
# один раз и не зависит от имени воркспейса. Порядок группировки/цикла cmd-j/cmd-k
# (search → hacking → main → other) задан отдельно в шаблоне и тоже не зависит от того,
# в каком порядке объявлены переменные ниже.

set -euo pipefail

WS_SEARCH="search"    # клавиша ctrl-s
WS_HACKING="hacking"  # клавиша ctrl-h
WS_MAIN="main"         # клавиша ctrl-m — основной воркспейс (фокус после логина)
WS_OTHER="other"      # клавиша ctrl-o

TEMPLATE="$HOME/.aerospace.template.toml"
TARGET="$HOME/.aerospace.toml"

if [ ! -f "$TEMPLATE" ]; then
    echo "Шаблон не найден: $TEMPLATE" >&2
    exit 1
fi

# Имена воркспейсов должны быть уникальны, иначе несколько правил/хоткеев схлопнутся
# на один и тот же воркспейс незаметно для пользователя.
names=("$WS_SEARCH" "$WS_HACKING" "$WS_MAIN" "$WS_OTHER")
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
    "$TEMPLATE" > "$TARGET"

echo "Сгенерирован $TARGET: search=$WS_SEARCH hacking=$WS_HACKING main=$WS_MAIN other=$WS_OTHER"

if command -v aerospace >/dev/null 2>&1; then
    aerospace reload-config
    echo "AeroSpace конфиг перезагружен"
fi
