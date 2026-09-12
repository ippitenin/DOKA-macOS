#!/bin/bash
# Проверка файлов локализации DOKA: парность ключей ru/en, дубли, плейсхолдеры,
# ключи из кода и мёртвые строки.
#
# Запускается и локально (гейт 2 из CLAUDE.md), и в CI. `swift build` синтаксис
# .strings не проверяет вообще, а рассинхрон ru/en не ловит даже plutil.
#
# Использование: ./scripts/check-localization.sh   (из DOKA-app/ или откуда угодно)
set -uo pipefail
cd "$(dirname "$0")/.."

RU="Sources/DOKA/Resources/ru.lproj/Localizable.strings"
EN="Sources/DOKA/Resources/en.lproj/Localizable.strings"
INFO_RU="Resources/ru.lproj/InfoPlist.strings"
INFO_EN="Resources/en.lproj/InfoPlist.strings"

# Ключи собираются интерполяцией `\(rawValue)` от String-enum'ов, поэтому в коде
# литералов нет — статический анализ обязан знать про них, иначе решит,
# что строки мёртвые. Плюс sidebar.group.* лежат в массиве SidebarView.
DYNAMIC_PREFIXES=(
    "transcribe.roles."
    "transcribe.llm.preset."
    "transcribe.llm.prompt."
    "transcribe.detail."
    "transcribe.diarizeSetting."
    "transcriptRetention."
    "sidebar.group."
    "analysis.template."
    "analysis.format."
    "analysis.prompt.format."
)

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "  ✗ $1"; FAILED=1; }
ok()   { echo "  ✓ $1"; }

# Формат строк строго `"ключ" = "значение";`, экранированных кавычек внутри нет,
# поэтому разбиение по " даёт ключ в $2 и значение в $4.
keys_of()   { awk -F'"' '/^"/ {print $2}' "$1"; }
values_of() { awk -F'"' '/^"/ {print $2 "\t" $4}' "$1"; }

# Плейсхолдеры значения в порядке появления: %@, %ld, %d, %.1f и подобные.
placeholders_of() {
    awk -F'"' '
    /^"/ {
        key = $2; val = $4; out = ""
        while (match(val, /%[0-9.]*(@|ld|lu|d|f|s)/)) {
            out = out substr(val, RSTART, RLENGTH) " "
            val = substr(val, RSTART + RLENGTH)
        }
        print key "\t" out
    }' "$1"
}

is_dynamic() {
    local key="$1"
    for prefix in "${DYNAMIC_PREFIXES[@]}"; do
        [[ "$key" == "$prefix"* ]] && return 0
    done
    return 1
}

echo "Проверка локализации DOKA"
echo

# ── 1. Файлы на месте и парсятся ───────────────────────────────────────────────
echo "1. Файлы и синтаксис"
for f in "$RU" "$EN" "$INFO_RU" "$INFO_EN"; do
    if [[ ! -f "$f" ]]; then
        fail "нет файла: $f"
        echo; echo "Проверка прервана."; exit 1
    fi
done
if plutil -lint "$RU" "$EN" "$INFO_RU" "$INFO_EN" >/dev/null 2>&1; then
    ok "plutil -lint: 4 файла"
else
    plutil -lint "$RU" "$EN" "$INFO_RU" "$INFO_EN" 2>&1 | grep -v ": OK$" | sed 's/^/    /'
    fail "plutil -lint нашёл ошибки синтаксиса"
fi

# ── 2. Парность ключей ru ↔ en ─────────────────────────────────────────────────
echo
echo "2. Парность ключей ru ↔ en"
keys_of "$RU" | sort > "$TMP/ru.keys"
keys_of "$EN" | sort > "$TMP/en.keys"
RU_COUNT=$(wc -l < "$TMP/ru.keys" | tr -d ' ')
EN_COUNT=$(wc -l < "$TMP/en.keys" | tr -d ' ')

ONLY_RU=$(comm -23 "$TMP/ru.keys" "$TMP/en.keys")
ONLY_EN=$(comm -13 "$TMP/ru.keys" "$TMP/en.keys")

if [[ -z "$ONLY_RU" && -z "$ONLY_EN" ]]; then
    ok "наборы совпадают ($RU_COUNT ключей)"
else
    [[ -n "$ONLY_RU" ]] && { echo "    Есть в ru, нет в en:"; echo "$ONLY_RU" | sed 's/^/      /'; }
    [[ -n "$ONLY_EN" ]] && { echo "    Есть в en, нет в ru:"; echo "$ONLY_EN" | sed 's/^/      /'; }
    fail "наборы ключей разошлись (ru: $RU_COUNT, en: $EN_COUNT)"
fi

# InfoPlist.strings пишет ключ без кавычек, поэтому парсер здесь другой.
info_keys_of() { sed -nE 's/^[[:space:]]*"?([A-Za-z][A-Za-z0-9_]*)"?[[:space:]]*=.*/\1/p' "$1" | sort; }
if diff -q <(info_keys_of "$INFO_RU") <(info_keys_of "$INFO_EN") >/dev/null; then
    ok "InfoPlist.strings: $(info_keys_of "$INFO_RU" | wc -l | tr -d ' ') ключ(ей), наборы совпадают"
else
    diff <(info_keys_of "$INFO_RU") <(info_keys_of "$INFO_EN") | sed 's/^/      /'
    fail "InfoPlist.strings: наборы ключей разошлись"
fi

# ── 3. Дубли внутри файла ──────────────────────────────────────────────────────
echo
echo "3. Дубли ключей"
for pair in "ru:$TMP/ru.keys" "en:$TMP/en.keys"; do
    lang="${pair%%:*}"; file="${pair#*:}"
    dups=$(uniq -d < "$file")
    if [[ -n "$dups" ]]; then
        echo "$dups" | sed 's/^/      /'
        fail "$lang: найдены дубли"
    fi
done
[[ $FAILED -eq 0 ]] && ok "дублей нет"

# ── 4. Плейсхолдеры совпадают ──────────────────────────────────────────────────
echo
echo "4. Плейсхолдеры ru ↔ en"
placeholders_of "$RU" | sort > "$TMP/ru.ph"
placeholders_of "$EN" | sort > "$TMP/en.ph"
PH_DIFF=$(diff "$TMP/ru.ph" "$TMP/en.ph" || true)
PH_COUNT=$(awk -F'\t' '$2 != ""' "$TMP/ru.ph" | wc -l | tr -d ' ')
if [[ -z "$PH_DIFF" ]]; then
    ok "совпадают ($PH_COUNT ключей с плейсхолдерами)"
else
    echo "$PH_DIFF" | sed 's/^/      /'
    fail "плейсхолдеры расходятся — падение будет в рантайме, не при сборке"
fi

# ── 5. Пустые значения ─────────────────────────────────────────────────────────
echo
echo "5. Пустые значения"
EMPTY=$(values_of "$RU" | awk -F'\t' '$2 == "" {print "ru: " $1}'; values_of "$EN" | awk -F'\t' '$2 == "" {print "en: " $1}')
if [[ -z "$EMPTY" ]]; then
    ok "пустых значений нет"
else
    echo "$EMPTY" | sed 's/^/      /'
    fail "есть пустые значения"
fi

# ── 6. Ключи из кода существуют в .strings ─────────────────────────────────────
echo
echo "6. Ключи из кода"
# Шаблоны с интерполяцией (`L("transcribe.detail.\(rawValue)")`) — не ключи;
# конкретные значения покрыты DYNAMIC_PREFIXES.
grep -rhoE 'L\("[^"]+"' Sources/DOKA --include='*.swift' \
    | sed -E 's/^L\("//; s/"$//' | grep -v '\\(' | sort -u > "$TMP/code.keys"
CODE_COUNT=$(wc -l < "$TMP/code.keys" | tr -d ' ')

MISSING=$(comm -23 "$TMP/code.keys" "$TMP/ru.keys")
if [[ -z "$MISSING" ]]; then
    ok "все $CODE_COUNT ключей из кода определены"
else
    echo "$MISSING" | sed 's/^/      /'
    fail "ключи используются в коде, но отсутствуют в .strings"
fi

# ── 7. Мёртвые ключи ───────────────────────────────────────────────────────────
echo
echo "7. Мёртвые ключи"
DEAD=""
while IFS= read -r key; do
    grep -qxF "$key" "$TMP/code.keys" && continue
    is_dynamic "$key" && continue
    DEAD+="$key"$'\n'
done < "$TMP/ru.keys"
DEAD=$(printf '%s' "$DEAD" | sed '/^$/d')

if [[ -z "$DEAD" ]]; then
    ok "неиспользуемых строк нет"
else
    echo "$DEAD" | sed 's/^/      /'
    fail "строки объявлены, но нигде не используются"
fi

echo
if [[ $FAILED -eq 0 ]]; then
    echo "Локализация в порядке."
else
    echo "Проверка не пройдена."
fi
exit $FAILED
