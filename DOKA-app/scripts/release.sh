#!/bin/bash
# Публикация релиза на GitHub: нотаризованный DOKA.dmg, архив автообновления
# DOKA-<версия>.zip, лента appcast.xml, тег и страница релиза.
# Использование: scripts/release.sh — версия берётся из Resources/Info.plist,
# заметки — из ReleaseNotes/<версия>.ru.md и .en.md (Markdown, обязательны).
#
# Релиз собирается на Mac сопровождающего, а не в CI: сертификат Developer ID,
# профиль нотаризации и секретный ключ EdDSA обновлений есть только там (см.
# «Подпись» в build.sh и Sources/DOKA/Update/CLAUDE.md). CI по тегу лишь
# проверяет, что сборка с чистого раннера проходит (release.yml).
#
# Лента — вложение релиза: установленные DOKA читают её по адресу
# releases/latest/download/appcast.xml (SUFeedURL), то есть всегда из
# последнего НЕ-пре-релиза. Коммитить в main при выпуске ничего не нужно.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="ippitenin/DOKA-macOS"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
TAG="v${VERSION}"
ROOT="$(cd .. && pwd)"
DMG="${ROOT}/DOKA.dmg"
UPDATE_ZIP="${ROOT}/DOKA-${VERSION}.zip"
NOTES_RU="ReleaseNotes/${VERSION}.ru.md"
NOTES_EN="ReleaseNotes/${VERSION}.en.md"
FEED_URL="$(plutil -extract SUFeedURL raw Resources/Info.plist)"

[ "$(git branch --show-current)" = "main" ] || { echo "Релиз собирается только с main"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Есть незакоммиченные изменения"; exit 1; }
git fetch -q origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "Локальный main не совпадает с origin/main"; exit 1; }
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "Тег ${TAG} уже есть — поднимите версию в Resources/Info.plist"
    exit 1
fi
# Заметки нужны до сборки: без них обновление пришло бы с пустым «Что нового».
for notes in "$NOTES_RU" "$NOTES_EN"; do
    [ -s "$notes" ] || { echo "Нет заметок релиза: $notes"; exit 1; }
    # Заметки идут в ленту внутри CDATA — эта последовательность её оборвала бы.
    if grep -F ']]>' "$notes" >/dev/null; then
        echo "В $notes есть «]]>» — уберите"; exit 1
    fi
done

./build.sh --dmg
# Нотаризует build.sh только с Developer ID; без него образ на чужом Mac
# потребовал бы «Открыть всё равно», и такой релиз выкладывать нельзя.
xcrun stapler validate -q "$DMG" || { echo "Образ не нотаризован — релиз не публикуется"; exit 1; }
[ -f "$UPDATE_ZIP" ] || { echo "Нет архива обновления $(basename "$UPDATE_ZIP") — его собирает build.sh --dmg"; exit 1; }

echo "==> Подпись обновления ключом EdDSA…"
SPARKLE_BIN="$(find .build/artifacts -type d -path '*Sparkle/bin' -prune -print -quit)"
[ -n "$SPARKLE_BIN" ] || { echo "Не найдены инструменты Sparkle (.build/artifacts/…/Sparkle/bin)"; exit 1; }
# Ключ в связке должен совпадать с SUPublicEDKey: иначе установленные DOKA
# отвергнут обновление, а заметим это только у пользователей.
PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw Resources/Info.plist)"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" \
    || { echo "В связке ключей нет ключа подписи обновлений (generate_keys)."; exit 1; }
[ "$KEYCHAIN_KEY" = "$PUBLIC_KEY" ] \
    || { echo "Ключ в связке ($KEYCHAIN_KEY) не совпадает с SUPublicEDKey ($PUBLIC_KEY)"; exit 1; }
# Выдаёт готовые атрибуты: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$UPDATE_ZIP")"
[[ "$SIGNATURE" == *'sparkle:edSignature="'*'length="'* ]] \
    || { echo "sign_update вернул неожиданное: $SIGNATURE"; exit 1; }

WORK="$(mktemp -d /tmp/doka-release.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APPCAST="$WORK/appcast.xml"
MIN_MACOS="$(sed -n 's/^MIN_MACOS=//p' scripts/build-shaders.sh)"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/$(basename "$UPDATE_ZIP")"

# Один элемент — последняя версия: Sparkle сравнивает sparkle:version
# (CFBundleVersion) с установленной. Заметки на двух языках, Sparkle берёт
# язык интерфейса DOKA (xml:lang), формат — Markdown (рендерит сама DOKA).
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DOKA</title>
    <link>https://github.com/${REPO}</link>
    <item>
      <title>DOKA ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description xml:lang="ru" sparkle:format="markdown"><![CDATA[
$(cat "$NOTES_RU")
]]></description>
      <description xml:lang="en" sparkle:format="markdown"><![CDATA[
$(cat "$NOTES_EN")
]]></description>
      <enclosure url="${ZIP_URL}" type="application/octet-stream" ${SIGNATURE}/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$APPCAST" || { echo "Лента appcast.xml собралась невалидной"; exit 1; }

NOTES_FILE="$WORK/notes.md"
{
    echo "## What's new"
    echo
    cat "$NOTES_EN"
    echo
    echo "## Что нового"
    echo
    cat "$NOTES_RU"
    echo
    cat <<'EOF'
---

## Installation

Download **DOKA.dmg** below, open it and drag DOKA to Applications. The app is signed with
Developer ID and notarized by Apple, so it opens like any other app — no extra steps.
DOKA 1.0.4 and newer update themselves: a new version downloads in the background and
installs with one click.

On first launch DOKA asks for **Microphone** access (to record your voice) and
**Accessibility** (to paste the text), then for a recognition service.

## Requirements

A Mac with Apple silicon (M1 or newer), macOS 15 (Sequoia) or newer. Intel Macs are not supported.

---

## Установка

Скачайте **DOKA.dmg** ниже, откройте и перетащите DOKA в «Программы». Приложение подписано
Developer ID и нотаризовано Apple, поэтому открывается как обычное — без дополнительных шагов.
DOKA 1.0.4 и новее обновляется сама: новая версия скачивается в фоне и ставится одной кнопкой.

При первом запуске DOKA попросит доступ к **микрофону** (запись голоса) и **универсальному
доступу** (вставка текста), затем — выбрать сервис распознавания.

## Требования

Mac с чипом Apple (M1 и новее), macOS 15 (Sequoia) или новее. Mac с процессором Intel не поддерживаются.
EOF
} > "$NOTES_FILE"

echo "==> Публикация ${TAG}…"
git tag -a "$TAG" -m "DOKA for macOS ${TAG}"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" "$UPDATE_ZIP" "$APPCAST" \
    --title "DOKA for macOS ${TAG}" --notes-file "$NOTES_FILE"

# Лента должна отдавать новую версию по постоянному адресу — именно его
# читают установленные DOKA. CDN GitHub обновляется не мгновенно.
echo "==> Проверка ленты ${FEED_URL}…"
for attempt in 1 2 3 4 5 6; do
    if curl -fsL "$FEED_URL" | grep -F "<sparkle:shortVersionString>${VERSION}<" >/dev/null; then
        echo "    Лента отдаёт ${VERSION}."
        break
    fi
    if [ "$attempt" = 6 ]; then
        echo "    ВНИМАНИЕ: лента пока не отдаёт ${VERSION} — проверьте $FEED_URL вручную."
    else
        sleep 10
    fi
done
echo "==> Готово: $(gh release view "$TAG" --json url -q .url)"
