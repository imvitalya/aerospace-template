#!/bin/bash
# Генерирует ~/.aerospace.toml из ~/.aerospace.template.toml, подставляя имена
# воркспейсов из переменных ниже. Чтобы переименовать воркспейс — поменяй значение
# здесь и запусти этот скрипт: ~/.aerospace-render.sh
#
# Физическая клавиша (ctrl-m/o/d/f и т.п.) при этом НЕ меняется — она задана в шаблоне
# один раз и не зависит от имени воркспейса.

set -euo pipefail

WS1="main"   # клавиша ctrl-m
WS2="other"  # клавиша ctrl-o
WS3="d"      # клавиша ctrl-d
WS4="f"      # клавиша ctrl-f

TEMPLATE="$HOME/.aerospace.template.toml"
TARGET="$HOME/.aerospace.toml"

if [ ! -f "$TEMPLATE" ]; then
    echo "Шаблон не найден: $TEMPLATE" >&2
    exit 1
fi

# Имена воркспейсов должны быть уникальны, иначе несколько правил/хоткеев схлопнутся
# на один и тот же воркспейс незаметно для пользователя.
names=("$WS1" "$WS2" "$WS3" "$WS4")
for i in "${!names[@]}"; do
    for j in "${!names[@]}"; do
        if [ "$i" -lt "$j" ] && [ "${names[$i]}" = "${names[$j]}" ]; then
            echo "Ошибка: имена воркспейсов должны быть разными (повтор: ${names[$i]})" >&2
            exit 1
        fi
    done
done

sed \
    -e "s/__WS1__/$WS1/g" \
    -e "s/__WS2__/$WS2/g" \
    -e "s/__WS3__/$WS3/g" \
    -e "s/__WS4__/$WS4/g" \
    "$TEMPLATE" > "$TARGET"

echo "Сгенерирован $TARGET: __WS1__=$WS1 __WS2__=$WS2 __WS3__=$WS3 __WS4__=$WS4"

if command -v aerospace >/dev/null 2>&1; then
    aerospace reload-config
    echo "AeroSpace конфиг перезагружен"
fi
