#!/bin/bash
# Сборка DOKA.app из SPM-пакета, подпись и установка в ~/Applications.
# Использование: ./build.sh [--dmg]
#   --dmg — дополнительно собрать DOKA.dmg в корне репозитория: образ с
#           приложением и симлинком на /Applications — привычная установка
#           перетаскиванием, как у приложений из интернета.
#
# Бинарник собирается универсальным (arm64 + x86_64): приложение раздаётся
# на Mac с чипами Apple Silicon, где Intel-срез работает только через Rosetta.
#
# ВАЖНО: папка проекта лежит на Рабочем столе, который синхронизируется iCloud.
# FileProvider вешает на файлы расширенные атрибуты, из-за которых codesign
# отказывается подписывать бандл («detritus not allowed»). Поэтому бандл
# формируется во временной папке вне iCloud и устанавливается в ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DOKA"
SIGN_ID="${DOKA_SIGN_ID:-DOKA Dev}"
INSTALL_DIR="${DOKA_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/${APP_NAME}.app"

MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        *) echo "Неизвестный аргумент: $arg (поддерживается только --dmg)"; exit 1 ;;
    esac
done

# Шейдеры панели записи: SwiftPM .metal не компилирует, а build-tool-плагин
# ломает мультиарх-сборку — поэтому metallib собирается заранее и уезжает
# в бандл обычным ресурсом (см. scripts/build-shaders.sh).
./scripts/build-shaders.sh

echo "==> Сборка release (swift build, universal arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

# При мультиарх-сборке (--arch … --arch …) SPM кладёт продукты
# не в .build/release, а в .build/apple/Products/Release.
BIN=".build/apple/Products/Release/${APP_NAME}"
[ -f "$BIN" ] || { echo "Бинарник не найден: $BIN"; exit 1; }
echo "    Архитектуры: $(lipo -archs "$BIN")"

echo "==> Формирование бандла во временной папке…"
STAGE="$(mktemp -d /tmp/doka-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
STAGE_APP="$STAGE/${APP_NAME}.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
# -X: не копировать расширенные атрибуты (iCloud/FileProvider-мусор)
cp -X "$BIN" "$STAGE_APP/Contents/MacOS/${APP_NAME}"
cp -X "Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"

# Иконка приложения (Finder/Get Info/Spotlight; в Dock не светится — accessory).
# Регенерация из Resources/AppIcon.png: scripts/make-appicon.sh.
# Именно if/fi: однострочный «[ ] &&» уронил бы сборку под set -e.
if [ -f "Resources/AppIcon.icns" ]; then
    cp -X "Resources/AppIcon.icns" "$STAGE_APP/Contents/Resources/AppIcon.icns"
fi

# Локализации уровня бандла (тексты системных запросов из InfoPlist.strings)
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -RX "$lproj" "$STAGE_APP/Contents/Resources/"
done

# Ресурсные бандлы SPM-зависимостей (KeyboardShortcuts ищет свой bundle через Bundle.module)
for b in .build/apple/Products/Release/*.bundle; do
    [ -e "$b" ] && cp -RX "$b" "$STAGE_APP/Contents/Resources/"
done

# llama.cpp — ДИНАМИЧЕСКИЙ фреймворк движка локального ИИ-анализа. Цикл
# «*.bundle» выше фреймворки не подхватывает, поэтому отдельный шаг. Берём из
# распакованного артефакта SPM, а не из Products: путь в Products зависит от
# версии swift-build, а в artifacts раскладка задана самим xcframework.
LLAMA_FW="$(find .build/artifacts -type d -path '*macos-arm64_x86_64/llama.framework' -prune | head -1)"
[ -n "$LLAMA_FW" ] || { echo "Не найден llama.framework (срез macos-arm64_x86_64)"; exit 1; }
# Срез обязан быть universal: иначе Intel-часть приложения не слинкуется и
# сломается уже после раздачи. Гейт здесь, а не в заметках к релизу.
LLAMA_ARCHS="$(lipo -archs "$LLAMA_FW/Versions/A/llama")"
if [[ "$LLAMA_ARCHS" != *arm64* || "$LLAMA_ARCHS" != *x86_64* ]]; then
    echo "llama.framework не universal ($LLAMA_ARCHS) — такой релиз llama.cpp брать нельзя"
    exit 1
fi
echo "    llama.framework: $LLAMA_ARCHS"
mkdir -p "$STAGE_APP/Contents/Frameworks"
# -R сохраняет симлинки Versions/Current, -X не тащит iCloud-xattr.
cp -RX "$LLAMA_FW" "$STAGE_APP/Contents/Frameworks/"
# Заголовки и modulemap в рантайме не нужны. Симлинки ВЕРХНЕГО уровня надо
# убирать вместе с целями: висячий симлинк роняет `codesign --verify --strict`.
FW="$STAGE_APP/Contents/Frameworks/llama.framework"
rm -rf "$FW/Versions/A/Headers" "$FW/Versions/A/Modules" "$FW/Headers" "$FW/Modules"

xattr -cr "$STAGE_APP" 2>/dev/null || true

# rpath на @executable_path/../Frameworks приходит из linkerSettings в
# Package.swift; страховка на случай, если swift-build его проглотит.
# Именно `grep >/dev/null`, а НЕ `grep -q`: с -q grep закрывает пайп на первом
# совпадении, otool получает SIGPIPE, и pipefail объявляет успешный поиск
# неудачей — rpath добавился бы вторым экземпляром.
if ! otool -l "$STAGE_APP/Contents/MacOS/${APP_NAME}" | grep "@executable_path/../Frameworks" >/dev/null; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGE_APP/Contents/MacOS/${APP_NAME}"
fi

echo "==> Подпись…"
# Вложенный фреймворк подписывается ПЕРВЫМ: у ggml-org он linker-signed
# (x86_64-срез вовсе без подписи), и подпись приложения поверх чужой
# не проходит `--strict`. install_name_tool выше тоже инвалидирует подпись.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$FW"
    codesign --force --deep --sign "$SIGN_ID" "$STAGE_APP"
    echo "    Подписано сертификатом «${SIGN_ID}» — TCC-разрешения стабильны между сборками."
else
    codesign --force --sign - "$FW"
    codesign --force --deep --sign - "$STAGE_APP"
    echo "    ВНИМАНИЕ: подпись ad-hoc. Разрешения микрофона/Accessibility будут"
    echo "    сбрасываться при каждой пересборке. Создайте сертификат «DOKA Dev»"
    echo "    по инструкции scripts/make-dev-cert.md и пересоберите."
fi
# --deep --strict: проверяет и вложенный фреймворк, и что в бандле нет
# постороннего «мусора» (висячих симлинков, неподписанных бинарников).
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

echo "==> Установка в ${APP}…"
mkdir -p "$INSTALL_DIR"
if pgrep -xq "$APP_NAME"; then
    echo "    DOKA запущен — завершаю перед заменой."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi
rm -rf "$APP"
mv "$STAGE_APP" "$APP"
echo "==> Готово: $APP"

if [ "$MAKE_DMG" = 1 ]; then
    DMG_PATH="$(cd .. && pwd)/${APP_NAME}.dmg"
    echo "==> Сборка образа ${DMG_PATH}…"
    # Содержимое образа: приложение + симлинк на /Applications для установки
    # перетаскиванием. Папка-источник — внутри $STAGE (вне iCloud), её
    # подчистит общий trap. Именно ditto: сохраняет подпись и структуру бандла.
    DMG_SRC="$STAGE/dmg"
    mkdir -p "$DMG_SRC"
    ditto "$APP" "$DMG_SRC/${APP_NAME}.app"
    ln -s /Applications "$DMG_SRC/Applications"
    rm -f "$DMG_PATH"
    # UDZO — сжатый read-only образ, стандарт раздачи приложений.
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_SRC" \
        -format UDZO -ov -quiet "$DMG_PATH"
    echo "    Готово: $(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')."
    echo "    На чужом Mac сертификат «${SIGN_ID}» неизвестен — Gatekeeper заблокирует"
    echo "    первый запуск: Системные настройки → Конфиденциальность и безопасность →"
    echo "    «Открыть всё равно», затем выдать разрешения микрофона и Accessibility."
fi
