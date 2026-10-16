#!/bin/bash
# Сборка DOKA.app из SPM-пакета, подпись и установка в ~/Applications.
# Использование: ./build.sh [--dmg]
#   --dmg — дополнительно собрать DOKA.dmg в корне репозитория: образ с
#           приложением и симлинком на /Applications — привычная установка
#           перетаскиванием, как у приложений из интернета.
#
# Подпись выбирается сама: сертификат «Developer ID Application» из связки
# ключей, если он есть, иначе самоподписанный «DOKA Dev», иначе ad-hoc. Только
# с Developer ID образ из --dmg уходит на нотаризацию Apple и открывается на
# чужом Mac без «Открыть всё равно» (профиль notarytool — DOKA_NOTARY_PROFILE).
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
# awk, а не `grep | head -1`: head закрыл бы пайп раньше времени, и под
# pipefail присваивание уронило бы сборку (та же ловушка, что с `grep -q` ниже).
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"Developer ID Application: / && !found { print $2; found = 1 }')"
SIGN_ID="${DOKA_SIGN_ID:-${DEVELOPER_ID:-DOKA Dev}}"
NOTARY_PROFILE="${DOKA_NOTARY_PROFILE:-apps-notary}"
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
# Ресурсные бандлы ушедших зависимостей SwiftPM из каталога продуктов НЕ
# удаляет, а цикл «*.bundle» ниже увёз бы их в приложение: после перехода на
# WhisperKit 1.x в DOKA.app так оставались бандлы swift-crypto и
# swift-transformers. Бандлы — выход сборки, нужные SwiftPM создаст заново.
rm -rf "$(swift build -c release --arch arm64 --show-bin-path)"/*.bundle
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
if [[ "$SIGN_ID" == "Developer ID Application: "* ]]; then
    IS_DEVELOPER_ID=1
else
    IS_DEVELOPER_ID=0
fi

# codesign с меткой времени, с повтором. Сервер меток Apple временами молчит
# («A timestamp was expected but was not found»), особенно после серии
# запросов, и разовый сбой ронял сборку на ровном месте. Повторяем подпись
# этого объекта с нарастающей паузой; любая другая ошибка — сразу наружу.
codesign_timestamped() {
    local delay out
    for delay in 5 20 60 0; do
        if out="$(codesign --timestamp "$@" 2>&1)"; then
            if [ -n "$out" ]; then echo "$out"; fi
            return 0
        fi
        if [ "$delay" = 0 ] || [[ "$out" != *"A timestamp was expected but was not found"* ]]; then
            echo "$out" >&2
            return 1
        fi
        echo "    Нет метки времени от Apple — повтор через ${delay} с…"
        sleep "$delay"
    done
}

if [ "$IS_DEVELOPER_ID" = 1 ]; then
    # Нотаризация требует hardened runtime и метку времени Apple. Под hardened
    # runtime микрофону и камере нужны права из Resources/DOKA.entitlements.
    # Без --deep: исполняемого кода в бандле ровно два куска, оба подписаны
    # явно, а --deep раздал бы права приложения и фреймворку.
    codesign_timestamped --force --options runtime --sign "$SIGN_ID" "$FW"
    codesign_timestamped --force --options runtime \
        --entitlements Resources/DOKA.entitlements --sign "$SIGN_ID" "$STAGE_APP"
    echo "    Подписано «${SIGN_ID}» (hardened runtime)."
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
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
# Завершаем только экземпляр из заменяемого бандла: сборка в другой каталог
# (DOKA_INSTALL_DIR) не должна убивать рабочую DOKA из ~/Applications.
RUNNING_BIN="$APP/Contents/MacOS/${APP_NAME}"
if pgrep -qf "^${RUNNING_BIN}( |\$)"; then
    echo "    DOKA запущен — завершаю перед заменой."
    pkill -f "^${RUNNING_BIN}( |\$)" || true
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

    if [ "$IS_DEVELOPER_ID" = 1 ]; then
        echo "==> Нотаризация (обычно несколько минут)…"
        # Подписанный образ Gatekeeper проверяет целиком, ещё до монтирования.
        codesign_timestamped --force --sign "$SIGN_ID" "$DMG_PATH"
        # Решаем по статусу из JSON, а не по коду возврата: так различаются
        # «до Apple не дошло» (статуса нет) и «Apple отклонила» (статус есть).
        NOTARY_JSON="$(xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
        NOTARY_STATUS="$(plutil -extract status raw - <<< "$NOTARY_JSON" 2>/dev/null)" || true
        if [ -z "$NOTARY_STATUS" ]; then
            echo "    Не удалось отправить на нотаризацию: нет сети или профиля «${NOTARY_PROFILE}»."
            if [ -n "$NOTARY_JSON" ]; then
                echo "    Ответ notarytool: $NOTARY_JSON"
            fi
            echo "    Профиль создаётся один раз (спросит пароль приложения от Apple ID):"
            echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <Apple ID> --team-id <Team ID>"
            exit 1
        fi
        if [ "$NOTARY_STATUS" != "Accepted" ]; then
            echo "    Apple отклонила сборку (статус ${NOTARY_STATUS}). Подробности:"
            xcrun notarytool log "$(plutil -extract id raw - <<< "$NOTARY_JSON")" \
                --keychain-profile "$NOTARY_PROFILE"
            exit 1
        fi
        # Квитанция внутри образа: Gatekeeper проверит его и без интернета.
        # Проверяем именно квитанцию, а не `spctl --assess`: на Mac с
        # выключенным Gatekeeper spctl принимает и ненотаризованный образ.
        xcrun stapler staple -q "$DMG_PATH"
        xcrun stapler validate -q "$DMG_PATH"
        echo "    Нотаризован: на чужом Mac откроется без предупреждений Gatekeeper."
    else
        echo "    На чужом Mac сертификат «${SIGN_ID}» неизвестен — Gatekeeper заблокирует"
        echo "    первый запуск: Системные настройки → Конфиденциальность и безопасность →"
        echo "    «Открыть всё равно», затем выдать разрешения микрофона и Accessibility."
    fi
fi
