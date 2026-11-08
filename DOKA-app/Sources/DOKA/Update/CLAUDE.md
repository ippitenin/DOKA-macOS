# Автообновление

Sparkle 2 со своим интерфейсом. Общие правила проекта, команды, гейты и сквозные инварианты — в корневом `CLAUDE.md` (там же подпись Sparkle.framework в `build.sh` и шаги релиза); пути вида `UI/CLAUDE.md` — от `DOKA-app/Sources/DOKA`.

## Как устроено

- **Лента** — `SUFeedURL` в `Info.plist`: `https://github.com/ippitenin/DOKA-macOS/releases/latest/download/appcast.xml`, вложение последнего (не пре-) релиза. Её собирает `scripts/release.sh`: один элемент с подписью EdDSA архива `DOKA-<версия>.zip` и заметками ru/en (`<description xml:lang=…>`, Sparkle берёт язык интерфейса). Публичный ключ — `SUPublicEDKey`, секретный — в связке ключей Mac сопровождающего.
- **Сборка без Developer ID** («DOKA Dev», ad-hoc, CI) — `build.sh` вырезает `SUFeedURL`, `UpdateController.isAvailable == false`, Sparkle не стартует, «О DOKA» ведёт на страницу релизов. Иначе самосборка молча заменилась бы официальной, а смена подписи сбрасывает разрешения и доступ к ключу API.
- **Интерфейс свой**: `DokaUserDriver` (протокол `SPUUserDriver`) переводит колбэки Sparkle в события `UpdateController`; состояние — чистый `UpdateState`, плашка — чистый `UpdateBannerModel.make` (оба покрыты `UpdateStateTests`). Стандартных окон Sparkle нет ни одного.

## Когда DOKA узнаёт о новой версии

- **Раз в час** (`SUScheduledCheckInterval = 3600`, минимум Sparkle) плюс **при запуске** (`checkForUpdatesInBackground` сразу после `start`, если с прошлой проверки прошло больше `UpdateSchedule.launchGap` = 5 мин) и **после сна** (`NSWorkspace.didWakeNotification` → `resetUpdateCycle`, если проверка просрочена: таймер Sparkle во сне стоит). Было раз в сутки — 1.0.5 владелец увидел только ручной проверкой (8.11.2026). Позже старта `checkForUpdatesInBackground` не звать: по документации Sparkle это ломает его планировщик, для пересчёта есть `resetUpdateCycle`.
- **Окно почти всегда закрыто** — поэтому сигнал в меню-баре: коралловая точка 6 pt в углу иконки (`MenuBarManager.badgeView`, отдельный слой поверх template-иконки) при `UpdateState.showsMenuBarBadge` (`.ready`, `.waitingForIdle`), к описанию VoiceOver добавляется «доступно обновление». В меню — «Обновить DOKA до X…» и «Что нового в X». Системное уведомление отвергнуто (решение владельца 8.11.2026): лишний запрос разрешения и шум.

## «Что нового»

Лист `ReleaseNotesSheet` — ОДИН на главное окно (`.sheet(isPresented: $updates.notesRequested)` в `MainWindowView`); открывают его плашка, ссылка в карточке статуса «О DOKA» и пункт меню-бара (`UpdateController.requestNotes`, из меню — после `showAbout`). Что показать — чистый `ReleaseNotesContent.make`: заметки найденной версии, пока её можно поставить, иначе — установленной. Заметки установленной версии переживают перезапуски: при первом запуске после обновления копия `DOKAUpdateHandoff` пишется в `DOKAInstalledNotes` и живёт, пока совпадает версия бандла (`InstalledNotes.resolve`). Лист снимает содержимое при открытии — фоновая проверка под открытым листом текст не подменяет.

## Два пути к установке

1. **Фоновое скачивание** (`SUAutomaticallyUpdate`, тумблер «Скачивать в фоне»): Sparkle тихо качает и распаковывает, затем зовёт делегат `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`. Возвращаем `true` (установку берём на себя) и храним блок; плашка — «Обновить», нажатие вызывает блок → перезапуск. Выход из DOKA ставит обновление и без кнопки — так Sparkle делает всегда.
2. **Без фонового скачивания или по ручной проверке**: `showUpdateFound` с ответом → плашка «Обновить» → `.install` → скачивание с прогрессом → `showReady(toInstallAndRelaunch:)` → сразу `.install`.

## Как выглядит установка (решения владельца 8.11.2026, «как в Telegram»)

- Нажатие «Обновить» (плашка, «О DOKA», меню-бар) не перезапускает DOKA мгновенно: `performInstall` гасит главное окно (`WindowManager.hideMainForUpdate`), показывает окно «Обновление DOKA» (`UI/UpdateInstallPanel.swift`, borderless-панель с материалом, через `PanelFade`) и плавно ведёт полосу `installProgress` к концу за ~2,8 с (`withAnimation`; своя полоса `SmoothProgressBar` — системный `ProgressView` на macOS прыгает), и только после паузы на 100 % зовёт блок Sparkle. Без фонового скачивания первые 60 % полосы — настоящая доля скачивания.
- Перед установкой в UserDefaults пишется `DOKAUpdateHandoff` (версия + заметки). Новая DOKA на старте сверяет её с `CFBundleShortVersionString` (`UpdateHandoff.resolve`) и показывает плашку «DOKA обновлена · Что нового» без кнопки (состояние `.updated`); запись одноразовая, при несовпадении версии стирается молча.
- Ручная проверка держит «Проверяю…» не меньше `UpdateTiming.minimumCheck` (1,2 с): ответ за миллисекунды дёргал карточку «О DOKA». Ответы Sparkle отдаются сразу, задерживается только смена `state`. Сама карточка статуса не меняет раскладку ни в одном состоянии (две строки всегда, кнопки в общем слоте) — тексты сменяются проявлением.
- Сорвалась установка (ошибка или Sparkle закрыл сессию при открытом окне установки) — окно прочь, главное окно назад, запись `DOKAUpdateHandoff` стирается.

## Инварианты

- **Не обрывать работу.** Установка ждёт покоя по `AppActivity.isBusy` (диктовка, распознавание файла, ИИ-анализ, фоновая работа библиотеки — тот же предикат, что у переноса «Папки данных»): состояние `waitingForIdle`, таймер раз в секунду. Страховка — делегат `shouldPostponeRelaunchForUpdate`.
- **Фоновые ошибки молчат** (только лог `[Update]`); `failed` показывается лишь после ручной проверки или нажатия «Обновить».
- Крестик плашки скрывает её до следующего запуска или следующей версии; точка и пункты меню-бара, «О DOKA» с «Что нового» остаются.
- Тумблеры «Проверять автоматически» и «Скачивать в фоне» хранит сам Sparkle (`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` в UserDefaults) — в `SettingsStore` не дублировать.
- Профиль системы Sparkle не отправляет (`SUEnableSystemProfiling` по умолчанию выключен): наружу уходит только запрос ленты к GitHub.

## Стенд обновления

`defaults write com.pitenin.doka DOKAUpdateFeedOverride <URL ленты>` — делегат `feedURLString(for:)` берёт ленту оттуда (пустое значение или удалённый ключ — снова `SUFeedURL`). Ленту стенда публикуют **пре-релизом**: `releases/latest` пре-релизы игнорирует, обычные пользователи стенд не увидят. После стенда — `defaults delete com.pitenin.doka DOKAUpdateFeedOverride` и удалить пре-релиз. Без публикации — локальный сервер: `python3 -I -m http.server 8765 --bind 127.0.0.1` в папке с архивом и лентой (ATS пропускает 127.0.0.1, Sparkle лишь предупреждает про HTTP), так проверялся 8.11.2026.
- **«Новая» версия стенда — снимок кода на момент её сборки.** Правки UI после сборки в неё не попадают: обновившись, увидишь СТАРЫЙ вид (так 8.11.2026 после обновления вернулись ссылка на GitHub и векторный логотип). После правок пересобирать обе стороны стенда.
- **Перед пересборкой «старой» стороны гасить ждущий установщик:** `pkill -f 'Sparkle.framework/Versions/B/(Autoupdate|Updater)'` и удалить `~/Library/Caches/com.pitenin.doka/org.sparkle-project.Sparkle`. Иначе `build.sh` завершит DOKA, а Autoupdate поставит скачанную версию поверх свежей сборки.
