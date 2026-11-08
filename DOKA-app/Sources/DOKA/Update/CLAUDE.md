# Автообновление

Sparkle 2 со своим интерфейсом. Общие правила проекта, команды, гейты и сквозные инварианты — в корневом `CLAUDE.md` (там же подпись Sparkle.framework в `build.sh` и шаги релиза); пути вида `UI/CLAUDE.md` — от `DOKA-app/Sources/DOKA`.

## Как устроено

- **Лента** — `SUFeedURL` в `Info.plist`: `https://github.com/ippitenin/DOKA-macOS/releases/latest/download/appcast.xml`, вложение последнего (не пре-) релиза. Её собирает `scripts/release.sh`: один элемент с подписью EdDSA архива `DOKA-<версия>.zip` и заметками ru/en (`<description xml:lang=…>`, Sparkle берёт язык интерфейса). Публичный ключ — `SUPublicEDKey`, секретный — в связке ключей Mac сопровождающего.
- **Сборка без Developer ID** («DOKA Dev», ad-hoc, CI) — `build.sh` вырезает `SUFeedURL`, `UpdateController.isAvailable == false`, Sparkle не стартует, «О DOKA» ведёт на страницу релизов. Иначе самосборка молча заменилась бы официальной, а смена подписи сбрасывает разрешения и доступ к ключу API.
- **Интерфейс свой**: `DokaUserDriver` (протокол `SPUUserDriver`) переводит колбэки Sparkle в события `UpdateController`; состояние — чистый `UpdateState`, плашка — чистый `UpdateBannerModel.make` (оба покрыты `UpdateStateTests`). Стандартных окон Sparkle нет ни одного.

## Два пути к установке

1. **Фоновое скачивание** (`SUAutomaticallyUpdate`, тумблер «Скачивать в фоне»): Sparkle тихо качает и распаковывает, затем зовёт делегат `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`. Возвращаем `true` (установку берём на себя) и храним блок; плашка — «Обновить», нажатие вызывает блок → перезапуск. Выход из DOKA ставит обновление и без кнопки — так Sparkle делает всегда.
2. **Без фонового скачивания или по ручной проверке**: `showUpdateFound` с ответом → плашка «Обновить» → `.install` → скачивание с прогрессом → `showReady(toInstallAndRelaunch:)` → сразу `.install`.

## Инварианты

- **Не обрывать работу.** Установка ждёт покоя по `AppActivity.isBusy` (диктовка, распознавание файла, ИИ-анализ, фоновая работа библиотеки — тот же предикат, что у переноса «Папки данных»): состояние `waitingForIdle`, таймер раз в секунду. Страховка — делегат `shouldPostponeRelaunchForUpdate`.
- **Фоновые ошибки молчат** (только лог `[Update]`); `failed` показывается лишь после ручной проверки или нажатия «Обновить».
- Крестик плашки скрывает её до следующего запуска или следующей версии; пункт меню-бара и «О DOKA» остаются.
- Тумблеры «Проверять автоматически» и «Скачивать в фоне» хранит сам Sparkle (`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` в UserDefaults) — в `SettingsStore` не дублировать.
- Профиль системы Sparkle не отправляет (`SUEnableSystemProfiling` по умолчанию выключен): наружу уходит только запрос ленты к GitHub.

## Стенд обновления

`defaults write com.pitenin.doka DOKAUpdateFeedOverride <URL ленты>` — делегат `feedURLString(for:)` берёт ленту оттуда (пустое значение или удалённый ключ — снова `SUFeedURL`). Ленту стенда публикуют **пре-релизом**: `releases/latest` пре-релизы игнорирует, обычные пользователи стенд не увидят. После стенда — `defaults delete com.pitenin.doka DOKAUpdateFeedOverride` и удалить пре-релиз.
