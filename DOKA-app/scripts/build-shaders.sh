#!/bin/bash
# Компиляция Metal-шейдеров панели записи в default.metallib.
#
# Зачем отдельный скрипт: SwiftPM .metal НЕ компилирует (кладёт файл в бандл
# как есть), а build-tool-плагин SPM ломает universal-сборку
# (`swift build --arch arm64 --arch x86_64` падает на резолве плагин-таргета).
# Поэтому metallib собирается заранее и попадает в бандл обычным ресурсом:
# `.process("Resources")` кладёт его в DOKA_DOKA.bundle, откуда build.sh
# забирает бандл своим циклом `*.bundle` — правок в build.sh не нужно.
#
# Файл сгенерированный, в git не хранится (см. .gitignore). После правки
# любого .metal скрипт надо прогнать заново, иначе `swift build` соберёт
# приложение со СТАРЫМ шейдером (или вовсе без него — панель покажет
# капсулу без эффекта и напишет об этом в лог).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Sources/DOKA/Resources/default.metallib"
SRC=(Shaders/*.metal)

# Минимальная версия macOS ЗАШИВАЕТСЯ в заголовок metallib, и без этого флага
# она берётся из SDK сборочной машины. На Xcode 26 это значит «нужна macOS 26»:
# на 14 и 15 `device.makeLibrary(URL:)` откажется грузить библиотеку,
# `DropShaders.isAvailable` станет false, и «Аврора» с «Мини» покажут пустую
# капельку без волны и капель. Приложение при этом не падает и в лог уходит
# только предупреждение — то есть фича молча мертва у всех, кто не на 26.
#
# Ни один гейт этого не ловил: CI работает на macos-26, где библиотека грузится.
# Значение обязано совпадать с `platforms: [.macOS(.v14)]` в Package.swift;
# ShaderLibraryTests сверяет зашитую версию с этой константой.
MIN_MACOS=14.0

echo "==> Компиляция шейдеров: ${SRC[*]} → $OUT (min macOS $MIN_MACOS)"
xcrun -sdk macosx metal -O -mmacosx-version-min="$MIN_MACOS" -o "$OUT" "${SRC[@]}"
echo "    Готово: $(du -h "$OUT" | cut -f1)"
