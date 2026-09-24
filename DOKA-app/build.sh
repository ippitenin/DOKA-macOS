#!/bin/bash
# Сборка DOKA.app из SPM-пакета, подпись и установка в ~/Applications.
# Использование: ./build.sh [--dmg]
#   --dmg — дополнительно собрать DOKA.dmg в корне репозитория: образ с
#           приложением и симлинком на /Applications — привычная установка
#           перетаскиванием, как у приложений из интернета.
#
# Сборка только под Apple Silicon (arm64). Intel не поддерживается: Parakeet
# и ИИ-анализ там не работали вовсе, а universal-сборка зажимала зависимости
# пинами (их мультиарх-сборка ломалась) и вдвое раздувала бинарник.
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

# Шейдеры панели записи: SwiftPM .metal не компилирует — metallib собирается
# заранее и уезжает в бандл обычным ресурсом (см. scripts/build-shaders.sh).
./scripts/build-shaders.sh

echo "==> Сборка release (swift build, arm64)…"
swift build -c release --arch arm64

# Каталог продуктов спрашиваем у самого SwiftPM: он зависит от версии
# swift-build (.build/release, .build/out/Products/Release, …).
PRODUCTS="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$PRODUCTS/${APP_NAME}"
[ -f "$BIN" ] || { echo "Бинарник не найден: $BIN"; exit 1; }
BIN_ARCHS="$(lipo -archs "$BIN")"
[ "$BIN_ARCHS" = "arm64" ] || { echo "Бинарник не arm64: $BIN_ARCHS"; exit 1; }
echo "    Архитектура: $BIN_ARCHS"

echo "==> Формирование бандла во временной папке…"
STAGE="$(mktemp -d /tmp/doka-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
STAGE_APP="$STAGE/${APP_NAME}.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
# -X: не копировать расширенные атрибуты (iCloud/FileProvider-мусор)
cp -X "$BIN" "$STAGE_APP/Contents/MacOS/${APP_NAME}"

# Версия SDK в заголовке бинарника (LC_BUILD_VERSION). SwiftPM пишет туда
# sdk = deployment target (15.0), хотя собирает SDK Xcode. AppKit по этой
# пометке решает, давать ли приложению новый дизайн: «собранному под 15» на
# macOS 26/27 достаются СТАРЫЕ кнопки окна, тумблеры, списки и ползунки.
# Переписываем sdk на фактический; minos остаётся минимальной системой —
# та же константа, что у шейдеров (обязана совпадать с Package.swift).
MIN_MACOS="$(sed -n 's/^MIN_MACOS=//p' scripts/build-shaders.sh)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
APP_BIN="$STAGE_APP/Contents/MacOS/${APP_NAME}"
vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
    -output "$APP_BIN.sdk" "$APP_BIN"
mv "$APP_BIN.sdk" "$APP_BIN"
# `grep >/dev/null`, а не `grep -q`: с -q otool получает SIGPIPE, и под
# pipefail проверка давала бы ложный отрицательный ответ.
if ! otool -l "$APP_BIN" | grep -E "^ +sdk $SDK_VERSION$" >/dev/null; then
    echo "Версия SDK в бинарнике не $SDK_VERSION — приложение получит старый вид контролов"
    exit 1
fi
echo "    SDK: $SDK_VERSION, минимум macOS $MIN_MACOS"
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
for b in "$PRODUCTS"/*.bundle; do
    [ -e "$b" ] && cp -RX "$b" "$STAGE_APP/Contents/Resources/"
done

# llama.cpp — ДИНАМИЧЕСКИЙ фреймворк движка локального ИИ-анализа. Цикл
# «*.bundle» выше фреймворки не подхватывает, поэтому отдельный шаг. Берём из
# распакованного артефакта SPM, а не из Products: путь в Products зависит от
# версии swift-build, а в artifacts раскладка задана самим xcframework.
# `-print -quit` вместо `| head -1`: под `set -o pipefail` head закрыл бы пайп,
# find получил бы SIGPIPE, и присваивание уронило бы сборку с пустым сообщением
# (та же ловушка, что с `grep -q` ниже).
LLAMA_FW="$(find .build/artifacts -type d -path '*macos-arm64_x86_64/llama.framework' -prune -print -quit)"
[ -n "$LLAMA_FW" ] || { echo "Не найден llama.framework (срез macos-arm64_x86_64)"; exit 1; }
mkdir -p "$STAGE_APP/Contents/Frameworks"
# -R сохраняет симлинки Versions/Current, -X не тащит iCloud-xattr.
cp -RX "$LLAMA_FW" "$STAGE_APP/Contents/Frameworks/"
# Заголовки и modulemap в рантайме не нужны. Симлинки ВЕРХНЕГО уровня надо
# убирать вместе с целями: висячий симлинк роняет `codesign --verify --strict`.
FW="$STAGE_APP/Contents/Frameworks/llama.framework"
rm -rf "$FW/Versions/A/Headers" "$FW/Versions/A/Modules" "$FW/Headers" "$FW/Modules"
# У ggml-org macOS-срез только universal: x86_64 вырезаем — он не нужен
# (приложение только arm64) и вдвое раздувает фреймворк. Если в новом релизе
# llama.cpp arm64 не окажется, `lipo -thin` уронит сборку сам.
LLAMA_BIN="$FW/Versions/A/llama"
if [[ "$(lipo -archs "$LLAMA_BIN")" != "arm64" ]]; then
    lipo "$LLAMA_BIN" -thin arm64 -output "$LLAMA_BIN.thin"
    mv "$LLAMA_BIN.thin" "$LLAMA_BIN"
fi
LLAMA_ARCHS="$(lipo -archs "$LLAMA_BIN")"
[ "$LLAMA_ARCHS" = "arm64" ] || { echo "llama.framework не arm64: $LLAMA_ARCHS"; exit 1; }
echo "    llama.framework: $LLAMA_ARCHS"

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
# Вложенный фреймворк подписывается ПЕРВЫМ: у ggml-org он linker-signed,
# `lipo -thin` выше его подпись всё равно снял, и подпись приложения поверх
# чужой не проходит `--strict`. install_name_tool выше тоже инвалидирует подпись.
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
