# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

DOKA (Dock Operations Kit for Apple) — меню-бар-приложение macOS для голосовой диктовки: глобальный хоткей → запись с микрофона → транскрипция через OpenAI-совместимый API → автозамены по словарю → вставка текста в активное приложение. Бывшее имя проекта — Whisper (осталась миграция данных).

Репозиторий — `ippitenin/DOKA-macOS` (до переименования `ippitenin/DOKA`, GitHub перенаправляет старые URL): это версия для Mac. iOS-версия — отдельный репозиторий `DOKA-iOS`, общего кода с этим нет. Суффикс `-macOS` относится только к репозиторию: имя продукта остаётся «DOKA», и `DOKA.app`, bundle id, таргет `DOKA`, `Application Support/DOKA`, аккаунты Keychain, `DOKA.dmg` под имя репозитория НЕ переименовывать — пользователи потеряют данные, TCC-разрешения и ключи.

Структура корня:
- `DOKA-app/` — само приложение (SPM executable, macOS 15+, AppKit + SwiftUI; зависимости — KeyboardShortcuts, WhisperKit из argmax-oss-swift и FluidAudio, две последние — для локальных моделей распознавания).
- `DOKA_LOGO/` — исходники фирменного логотипа (`Vector_DOKA.svg/.pdf`); из `Vector_DOKA.svg` 1:1 перенесён контур `DokaPetalsShape` (см. дизайн-систему в `Sources/DOKA/UI/CLAUDE.md`). `media/` — картинки для README.
- `SMOKE.md` — чек-лист ручного smoke по областям (гейт 5 ниже).
- `README.md` / `README.ru.md`, `CONTRIBUTING.md` / `CONTRIBUTING.ru.md` — документация на двух языках; при правке одной версии обязательно править парную. `LICENSE` — GPL-3.0.

Локальные материалы вне репозитория (лежат на диске, перечислены в `.gitignore` — проект открыт, и в публичную историю они не попадают):
- `DOCS/NEXARA/` — локальная копия документации API Nexara: снимок docs.nexara.ru из дампа `llms-full.txt`, по странице на файл `GUIDES/<slug>.md`; дата дампа, способ регенерации и список пустых страниц — в `DOCS/NEXARA/README.md`. Не публикуется: это дословный чужой контент. `DOCS/superpowers/` — спеки и планы фич.
- `HISTORY-ARCHIVE/` — приватная история разработки до открытия исходников (58 коммитов: развёрнутый git-репозиторий плюс бандл `DOKA-history-backup.bundle` на случай восстановления). В публичную историю не переносится и в репозиторий не входит.
- Черновики соседних продуктов в корне (PRD и HTML-прототип) к коду DOKA-app отношения не имеют и в репозиторий не входят.

Язык кода и комментариев — русский. Строки интерфейса — только через `L("ключ")` (хелпер в `Sources/DOKA/Localization.swift`); каждый ключ обязан присутствовать в обоих файлах `Sources/DOKA/Resources/{ru,en}.lproj/Localizable.strings`. Второй слой локализации — `DOKA-app/Resources/{ru,en}.lproj/InfoPlist.strings` (тексты системных запросов разрешений): эти файлы `swift build` вообще не видит, в бандл их кладёт `build.sh`. Внимание: `swift build` НЕ валидирует синтаксис `.strings` — после правок прогонять `plutil -lint`. Язык интерфейса переключается настройкой `SettingsStore.appLanguage` (механизм `AppleLanguages`, применяется после перезапуска); названия языков в `AppLanguage.title` намеренно не локализуются — каждое на своём языке.

## Команды

Все команды выполняются из `DOKA-app/`:

```bash
# Debug-сборка и тесты — только со scratch-каталогом вне iCloud: в папке проекта
# на macOS 27 подпись ресурсных бандлов падает (см. «Особенности сборки»).
scripts/build-shaders.sh                       # default.metallib: на свежей копии ДО swift test
                                               # (иначе падают тесты шейдеров) и после правки Shaders/*.metal
swift build --scratch-path /tmp/doka-build     # проверка компиляции (debug, нативная архитектура)
swift test  --scratch-path /tmp/doka-build     # все тесты чистой логики (несколько секунд)
swift test  --scratch-path /tmp/doka-build --filter DictationGateTests                               # один класс
swift test  --scratch-path /tmp/doka-build --filter DictationGateTests/testShortRecordingIsDropped   # один тест
scripts/check-localization.sh                  # plutil -lint всех 4 .strings + парность ключей ru/en,
                                               # плейсхолдеры, ключи из L(...), мёртвые строки
DOKA_SMOKE=1 swift test --scratch-path /tmp/doka-build --filter LiveSmokeTests   # живой smoke локальных
                                               # моделей (~40 с; подробности — Tests/DOKATests/CLAUDE.md)

./build.sh         # release-сборка (только arm64), подпись, установка в ~/Applications/DOKA.app
./build.sh --dmg   # то же + сборка DOKA.dmg в корне репозитория (hdiutil, UDZO): образ с приложением
                   # и симлинком на /Applications — установка перетаскиванием (артефакт в .gitignore)
./run.sh           # build.sh + запуск приложения

scripts/make-appicon.sh [исходник.png]   # перегенерация Resources/AppIcon.icns
                                         # (по умолчанию из Resources/AppIcon.png; поля по сетке macOS)
```

Коммиты — conventional commits с описанием на русском: `feat:` / `fix:` / `docs:` / `chore:` (см. `git log`).

### Гейты верификации

Тесты чистой логики — `Tests/DOKATests` (XCTest, плюс 7 живых `LiveSmokeTests`, по умолчанию пропущенных); класс назван по типу, который проверяет, — полный список даёт `ls Tests/DOKATests`. Карта покрытия по областям, ловушки тестов, живой smoke локальных моделей и стенды вне приложения — `DOKA-app/Tests/DOKATests/CLAUDE.md`.

**Ловушка, стоившая отдельного теста.** `TranscriptionProvider.openai` и `.groq` выглядят мёртвыми (в пикере их нет), но `HistorySectionView`, `TranscriptionControls` и `PerformanceAnalysisView` разбирают ими поле `provider` СТАРЫХ записей истории через `TranscriptionProvider(rawValue:)?.title ?? raw`. Удалить кейсы — показать людям сырые строки вместо названий сервисов. То же с `RecordSummary.preview` и `FileTranscriptRecord.updatedAt`: читателей в UI нет, но они ПЕРСИСТЯТСЯ в `meta.json`, и удаление не-опционального поля сделало бы новый файл нечитаемым для предыдущей версии приложения.

Вне покрытия принципиально: запись звука, вставка через CGEvent, Keychain, панели рекордера, сетевые запросы — им нужен живой Mac с разрешениями. Поэтому гейты остаются:

1. `swift build` — без предупреждений, затем `swift test` — все зелёные. **Автоматизировано** в CI (`.github/workflows/build.yml`): гейт предупреждений грепает лог по `Sources/DOKA/` и по имени пакета `'doka-app'` (предупреждения уровня пакета вроде «found N file(s) which are unhandled» пути в строке не содержат), потому что `-warnings-as-errors` применился бы и к FluidAudio, у которой три своих предупреждения.
2. **Шейдеры**: после правки любого `Shaders/*.metal` — `scripts/build-shaders.sh`. SwiftPM `.metal` НЕ компилирует, поэтому голый `swift build` соберёт приложение со старым шейдером (или вовсе без него — капелька «Авроры» останется пустой, в лог уйдёт предупреждение). `build.sh` зовёт скрипт сам, в CI это отдельный шаг, а `ShaderLibraryTests` проверяет и наличие `default.metallib` в бандле, и имена функций — но только на ЧИСТОЙ сборке: на грязном `.build` старый metallib остаётся лежать в бандле и тест зеленеет вхолостую.
3. `plutil -lint` обоих `Localizable.strings` (при их правке — и обоих `InfoPlist.strings`): `swift build` синтаксис `.strings` НЕ проверяет. **Автоматизирован** там же, вместе со `scripts/check-localization.sh` — он сверяет парность ключей ru/en, дубли, плейсхолдеры, наличие ключей из `L(...)` и отсутствие мёртвых строк. В `DYNAMIC_PREFIXES` скрипта десять записей. Восемь — настоящая интерполяция `\(rawValue)`: `transcribe.roles.`, `transcribe.llm.preset.`, `transcribe.llm.prompt.`, `transcribe.detail.`, `transcribe.diarizeSetting.`, `transcriptRetention.`, `analysis.template.`, `analysis.format.`. Ещё `sidebar.group.` собирается из массива в `SidebarView`, а `analysis.prompt.format.` вписан с запасом — эти ключи в `AnalysisPromptBuilder` пока литеральные, и скрипт нашёл бы их и без префикса. При добавлении новых динамических ключей список `DYNAMIC_PREFIXES` надо пополнять, иначе строки будут объявлены мёртвыми.
4. `./build.sh` — release + подпись. В CI выполняется только по тегу (`.github/workflows/release.yml`) и уходит в ad-hoc-ветку подписи: сертификата «DOKA Dev» на раннере нет. **Отдельно для llama.framework** (движок ИИ-анализа): `lipo -archs .../Contents/Frameworks/llama.framework/Versions/A/llama` — обязан быть ровно `arm64`; `otool -L .../MacOS/DOKA | grep llama.framework` и `otool -l ... | grep '@executable_path/../Frameworks'`; `codesign --verify --deep --strict`. Те же проверки (плюс `lipo -archs` самого бинарника) стоят шагом в `release.yml`; сам `build.sh` вырезает из фреймворка x86_64 (`lipo -thin arm64`) и роняет сборку guard'ом `lipo`, если бинарник или фреймворк не ровно `arm64`.
5. Ручной smoke по затронутым областям — чек-лист `SMOKE.md` в корне репозитория, в описание PR выписываются пункты затронутых областей (движки локальных моделей сначала прогоняет `LiveSmokeTests` — руками остаются интерфейс и железо: нажатие хоткея, микрофон, вставка, вид панелей).

Переменные окружения сборки: `DOKA_SIGN_ID` (имя сертификата, по умолчанию «DOKA Dev»), `DOKA_INSTALL_DIR` (по умолчанию `~/Applications`).

### Особенности сборки — не «чинить»

- **iCloud**: проект лежит на Рабочем столе, синхронизируемом iCloud. FileProvider вешает на файлы xattr, из-за которых `codesign` падает («detritus not allowed»). Поэтому `build.sh` собирает бандл во временной папке в `/tmp` и копирует с `cp -X`. Не пытаться подписывать бандл внутри папки проекта.
- **Подпись**: нужен самоподписанный сертификат «DOKA Dev» (инструкция — `DOKA-app/scripts/make-dev-cert.md`). При ad-hoc подписи macOS сбрасывает TCC-разрешения (микрофон, Accessibility) на каждой пересборке.
- **Шейдеры и SPM**: `default.metallib` собирается ОТДЕЛЬНЫМ скриптом и лежит в `Sources/DOKA/Resources` (в `.gitignore` — артефакт сборки), откуда `.process("Resources")` кладёт его в `DOKA_DOKA.bundle`, а `build.sh` забирает бандл своим циклом `*.bundle` — правок в копировании не нужно. Build-tool-плагин SwiftPM когда-то отвергли: на мультиарх-сборке `--arch arm64 --arch x86_64` он падал с «Unable to resolve build file … missing target» (воспроизводилось на пустом пакете). Сейчас сборка только arm64, и эта причина снята, но рабочий скрипт на непроверенный плагин менять незачем. Исходники шейдеров лежат в `DOKA-app/Shaders/`, а не в `Sources/`, тоже намеренно: `.metal` внутри таргета даёт предупреждение «found 1 file(s) which are unhandled», которое уронит гейт предупреждений.
- **Только Apple Silicon (arm64)**: release собирается `swift build -c release --arch arm64`; Intel не поддерживается (решение пользователя, 23.09.2026: Parakeet и ИИ-анализ на Intel не работали вовсе, universal-сборка зажимала зависимости пинами и вдвое раздувала бандл — 62 → 32 МБ после отказа). Каталог продуктов `build.sh` спрашивает у SwiftPM (`--show-bin-path`), а не хардкодит: он зависит от версии swift-build (`.build/release`, `.build/out/Products/Release`, у мультиарх — `.build/apple/Products/Release`). Intel-веток в коде нет: arm64-бинарник на Intel-маке просто не запускается, поэтому `#if arch`, барьеры скачивания и Intel-предупреждения удалены — не возвращать.
- **Debug-сборка в папке проекта на macOS 27** падает на подписи ресурсных бандлов («detritus not allowed» — та же iCloud-ловушка): новый swift-build подписывает и debug-бандлы. Проверять компиляцию и тесты с build-папкой вне iCloud: `swift build --scratch-path /tmp/doka-build` (и `swift test` с тем же флагом). Release-сборка `build.sh` в папке проекта при этом проходит.
- **Пометка SDK в бинарнике (`LC_BUILD_VERSION`) переписывается `vtool` в `build.sh`.** SwiftPM пишет туда `sdk` = deployment target (15.0), хотя собирает SDK Xcode, а AppKit по этой пометке («linked-on SDK») решает, давать ли приложению новый дизайн: «собранному под 15» на macOS 26/27 достаются СТАРЫЕ кнопки окна (светофор), тумблеры, списки и ползунки — при том что явный `glassEffect` работает. `build.sh` ставит `sdk` = `xcrun --show-sdk-version`, `minos` — `MIN_MACOS` из `scripts/build-shaders.sh`, и роняет сборку, если пометка не совпала; та же проверка — в `release.yml`. Голые `swift build`/`swift run` по-прежнему дают `sdk 15.0`: вид контролов проверять только на бандле из `build.sh`.
- `build.sh` убивает запущенный процесс DOKA перед заменой бандла.
- **Минимум — macOS 15, и это не косметика.** Подняли с 14 из-за бага Apple
  (FluidAudio #878): на macOS 14 офлайновая диаризация роняет приложение —
  `EXC_BAD_ACCESS` в `libBNNS` (`BNNSGraphContextExecute_v2` → `_platform_memmove`).
  Матрица upstream: macos-14 — 1200/1200 крэшей, macos-15 и 26 — ноль на том же
  коде. Библиотечного обхода нет, починено в самой macOS 15; в 0.15.6 добавлено
  только предупреждение в лог. Понижать `platforms` обратно нельзя.
- **Шейдеры собираются с `-mmacosx-version-min`.** Компилятор Metal зашивает
  минимальную версию ОС в заголовок metallib и без флага берёт её из SDK
  сборочной машины: на Xcode 26 это давало «нужна macOS 26», и на всех
  системах ниже `makeLibrary(URL:)` молча отказывался грузить библиотеку —
  «Аврора» и «Мини» показывали пустую капельку. Ни сборка, ни CI этого не
  ловили (оба на macOS 26). `MIN_MACOS` в `scripts/build-shaders.sh` обязан
  совпадать с `platforms` в `Package.swift`; `ShaderLibraryTests` сверяет
  зашитую версию, читая байт по смещению 12 в заголовке (0x0f = 15).

## Архитектура

Точка входа `main.swift`: `LegacyMigration.run()` (обязательно до первого чтения настроек) → `AppDelegate`. Приложение — `.accessory` / `LSUIElement`: только меню-бар, без Dock.

**Центр всего — `DictationController`** (`Sources/DOKA/DictationController.swift`): конечный автомат `idle → recording → transcribing → idle` плюс состояние `error`. Счётчик поколений `generation` инвалидирует устаревшие задачи транскрипции: любая смена состояния увеличивает его, и задача со старым значением не имеет права трогать автомат или вставлять текст. Любое изменение жизненного цикла диктовки проходит через `transition(to:)`.

**Владение объектами**: `AppDelegate` владеет всеми верхнеуровневыми объектами (DictationController, HotkeyManager, MenuBarManager, RecorderPanelController); остальные держат `weak`-ссылки. Весь код `@MainActor`.

**Поток данных диктовки**:
`HotkeyManager` (KeyboardShortcuts) → `DictationController` → `AudioRecorder` (WAV во временный файл) → `TranscriptionClient` (multipart POST на `/audio/transcriptions`) → `HallucinationFilter` → `DictationCleanupRunner` (ИИ-обработка на языковой модели этого Mac, по умолчанию ВЫКЛ; см. `Text/CLAUDE.md`) → `ReplacementEngine` (правила словаря) → `HistoryStore` (JSON в Application Support/DOKA, максимум 200 записей; метаданные — всегда, сжатое m4a-аудио — только если включён тоггл `SettingsStore.saveAudio`, по умолчанию ВЫКЛ; см. `Storage/CLAUDE.md`) и `StatsStore` (lifetime-агрегаты для дашборда) → `Paster` (буфер обмена + синтетический Cmd+V через CGEvent). Кодирование m4a — ещё один `await` в пайплайне (между распознаванием и вставкой), поэтому при выключенном `saveAudio` его пропускают целиком и вставка быстрее; после кодирования автомат повторно проверяет `generation` (отменённая диктовка не пишется в историю и не вставляется). Ключевые переходы автомата озвучиваются системными звуками macOS через `SoundPlayer` (`Audio/SoundPlayer.swift`: старт/стоп/отмена/ошибка), гейтится настройкой `SettingsStore.soundsEnabled`.

**Сервисы транскрипции**: встроенный Nexara (`builtin`), две локальные модели (`local:whisper`/`local:parakeet`) и пользовательские пресеты (`custom:<uuid>`); выбор — `SettingsStore.providerID`. Доступ к активному сервису — ТОЛЬКО через фасады `SettingsStore` (`isServiceReady`, `resolveRoute`, `currentAPIKey`, `providerConfig` …), ветвление «локальный/сетевой» в контроллерах — ТОЛЬКО свитчем по `ServiceRoute` из `resolveRoute()`. Подробно — `Sources/DOKA/Network/CLAUDE.md`, локальные модели — `Sources/DOKA/Local/CLAUDE.md`.

**Синглтоны**: `SettingsStore.shared` (обёртка над UserDefaults, все настройки `@Published`), `HistoryStore.shared`, `AudioStore.shared` (сжатое аудио истории на диске), `TranscriptHistoryStore.shared` (библиотека транскрибаций файлов), `LibraryModel.shared` (состояние секции «Библиотека»), `RecordingPlayer.shared` (воспроизведение записей истории и библиотеки), `StatsStore.shared` (агрегаты статистики диктовки), `PermissionsManager.shared` (микрофон + Accessibility; камера — отдельно, в `allGranted` не входит), `WindowManager.shared`, `LipCapture.shared` (камера эксперимента «Губы»), `LipDataStore.shared` (пары «губы + текст»), `LipTrainingController.shared` (окно «Тренировка»).

**UI — два слоя**:
- Главное окно (`UI/WindowControllers.swift` + `UI/Main/`): ленивый NSWindow с SwiftUI `MainWindowView`, сайдбар с секциями (enum `MainSection`: home/dashboard/general/sound/hotkeys/dictionary/service/history/transcribe/library/lips; группа сайдбара «Диктовка» — transcribe, library, history, dictionary, а `lips` — только при включённом эксперименте «Губы»). Внимание к названиям: `home` в UI называется «DOKA» (онбординг/готовность к диктовке), а `dashboard` в UI называется «Дашборд» — экран статистики диктовки (ключ `section.dashboard`). Окно переживает закрытие (`isReleasedWhenClosed = false`).
- Плавающая панель записи (`UI/RecorderPanel.swift`, контроллер `RecorderPanelController`): borderless non-activating `NSPanel`, никогда не становится key — фокус остаётся в целевом приложении. Стили, шейдеры и ловушки — `Sources/DOKA/UI/CLAUDE.md`, экраны главного окна — `Sources/DOKA/UI/Main/CLAUDE.md`.

## Карта документации

Подробности областей — в `CLAUDE.md` их папок: Claude Code подгружает такой файл сам, когда читает файлы папки (и все `CLAUDE.md` по пути к ней). Задача задевает область из другой папки — прочитай её файл до правок. Правишь код — обнови документ его папки; новое сквозное правило — сюда. Новый `CLAUDE.md` в папке таргета (`Sources/DOKA/…`, `Tests/DOKATests`) — сразу в `exclude` этого таргета в `Package.swift`: иначе SwiftPM считает его необработанным файлом и выдаёт предупреждение (гейт CI его ловит). Пути ниже — от корня репозитория, `…` = `DOKA-app/Sources/DOKA`.

| Документ | Что внутри |
|---|---|
| `SMOKE.md` | чек-лист ручного smoke по областям (гейт 5) |
| `DOKA-app/Tests/DOKATests/CLAUDE.md` | карта покрытия тестов, ловушки тестов, `LiveSmokeTests`, проверки вне приложения |
| `…/Audio/CLAUDE.md` | гейт тишины и повтор диктовки, тихий режим, уровень микрофона для панелей, «Звук», плеер записей |
| `…/Text/CLAUDE.md` | ИИ-обработка диктовки, фильтр галлюцинаций, словарь замен |
| `…/Paste/CLAUDE.md` | вставка: `Paster`, `keyUp`, буфер обмена, пробел между диктовками |
| `…/Network/CLAUDE.md` | сервисы транскрипции и фасады, сетевой клиент файлов, гейт Nexara-параметров, async-режим |
| `…/Local/CLAUDE.md` | локальные модели (Whisper, Parakeet), диаризация, llama.cpp и языковая модель, ленивая загрузка движков |
| `…/Lips/CLAUDE.md` | эксперимент «Губы»: камера, Vision, хранилище пар, зеркало, «Тренировка» |
| `…/Storage/CLAUDE.md` | библиотека транскрибаций на диске, «Папка данных», аудио истории и срок хранения |
| `…/Managers/CLAUDE.md` | клавиши и кнопка мыши, уведомления о файлах |
| `…/UI/CLAUDE.md` | панели записи (стили, шейдеры), дизайн-система, правила для любого UI |
| `…/UI/Main/CLAUDE.md` | экраны главного окна: «Транскрибация», дашборд, история, «Сервис», «Расширенные», онбординг |
| `…/UI/Main/Library/CLAUDE.md` | экран «Библиотека», спикеры и правка текста |
| `…/Util/CLAUDE.md` | ИИ-анализ (облако и Mac, шаблоны, «Угадать имена», Markdown и PDF) и указатель по остальным файлам `Util/` |

### Неочевидные инварианты

- Глобальный Esc (`cancelRecording`) включается только на время записи/распознавания через `HotkeyManager.setEscapeEnabled` — иначе DOKA перехватит Esc во всей системе.
- **Перенос «Папки данных» останавливает ВЕСЬ пайплайн, а не только библиотеку.** У
  `HistoryStore`, `StatsStore` и `AudioStore` своей заморозки нет: путь они фиксируют
  один раз в `init` и создаются ДО переноса, поэтому продолжали бы писать в старую
  папку. Закрыто флагом `AppDataFolder.needsRestart` (ставится после успешного
  переноса): `DictationController.startRecording` отказывает с
  `transcribe.error.restartRequired`. Нет записи — нет и записей в историю,
  статистику и аудио. Гейт самого переноса (`AdvancedSettingsView.migrate`) ждёт
  покоя от четверых: файловой транскрибации, диктовки (`DictationController.isActive`),
  ИИ-анализа (`AnalysisController.isRunning`) и фоновых задач библиотеки.
- **Взаимоисключение «анализ ↔ локальное распознавание» — по маршруту ИДУЩЕГО
  прогона** (`FileTranscriptionController.runningUsesLocalEngine`), а не по глобальному
  `providerID`: запуск из библиотеки идёт по снимку `params.providerID`, и глобальная
  настройка к нему отношения не имеет. Гейт двусторонний: анализ не стартует поверх
  локального распознавания, локальное распознавание — поверх анализа. Сетевому
  распознаванию анализ не мешает, и наоборот.
- `AppDelegate.installEditMenu()` создаёт невидимое меню «Правка»: без него Cmd+C/V/X/A не работают в текстовых полях меню-бар-приложения.
- `LegacyMigration` — одноразовый перенос из старого приложения Whisper (`com.pitenin.whisper`): UserDefaults (включая хоткеи), ключ Keychain, история. Копирует, а не переносит.
- Синхронное чтение Keychain в пути запуска (`applicationDidFinishLaunching`) ЗАМОРАЖИВАЕТ всё приложение, если macOS показывает диалог подтверждения доступа к ключу (случается после пересборки бинарника): `SecItemCopyMatching` блокирует главный поток до ответа пользователя. Поэтому `resumePendingJobs` читает ключ лениво через `Task.detached`. Такое же синхронное чтение осталось в `AppDelegate` (`SettingsStore.currentAPIKey` при старте) — известное место: при висящем диалоге запуск блокируется там. По той же причине `isServiceReady` НЕЛЬЗЯ звать из тела SwiftUI-вью для сетевого сервиса (у него внутри `currentAPIKey`): онбординг мемоизирует результат в `@State keyStatus` и обновляет его по событию (`syncServiceState()` из `onAppear` и `onChange(of: providerID)`), а из тела спрашивает `isServiceReady` только для локального сервиса — там Keychain не участвует. Тело `HomeSectionView` перерисовывается на каждый процент скачивания модели, и прямой вызов дал бы сотню `SecItemCopyMatching` за загрузку.
