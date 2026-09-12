import AppKit
import Foundation

/// Записанная диктовка, готовая к распознаванию.
struct RecordedDictation: Equatable {
    let url: URL
    let duration: TimeInterval
    let speechDuration: TimeInterval
    let microphone: String?
}

/// Последняя неудачная попытка распознавания — один слот на приложение,
/// только в памяти (WAV лежит во временной папке). «Повторить неудачную
/// диктовку» в меню-баре распознаёт её заново, возможно уже другим сервисом.
struct FailedDictation: Equatable {
    let audio: RecordedDictation
    let failedAt: Date
    let message: String
    /// Запись отсеяна гейтом тишины, а не упала при распознавании. Такая
    /// «возможно, тишина» не вправе вытеснить из слота настоящую неудачу.
    var gated = false
}

/// Конечный автомат диктовки: idle → recording → transcribing → idle.
/// Управляет записью, обращением к сервису распознавания, заменами,
/// вставкой и историей.
///
/// Счётчик поколений `generation` инвалидирует «зависшие» задачи: любая смена
/// состояния увеличивает его, и задача транскрипции, захватившая старое значение,
/// не имеет права трогать автомат или вставлять текст.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case error(message: String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published var audioLevel: Float = 0
    /// Слот повтора: запись, которую не удалось распознать (или которую гейт
    /// тишины отсеял, а она длиннее секунды). nil — повторять нечего.
    @Published private(set) var lastFailedDictation: FailedDictation?

    /// Слабые ссылки: владеет всеми объектами AppDelegate.
    weak var hotkeys: HotkeyManager?
    weak var panelController: RecorderPanelController?
    /// Открытие онбординга, если не хватает разрешений или ключа.
    var onNeedsOnboarding: (() -> Void)?

    private let recorder = AudioRecorder()
    private let micBooster = MicrophoneVolumeBooster()
    private let client = TranscriptionClient()
    private let settings = SettingsStore.shared
    private let history = HistoryStore.shared
    private let stats = StatsStore.shared
    private var errorDismissTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var generation = 0

    /// Откуда запись: только что надиктована или взята из слота повтора.
    private enum DictationSource {
        case live
        /// `targetPID` — приложение, которое было впереди в момент повтора:
        /// вставляем, только если оно всё ещё впереди.
        case retry(targetPID: pid_t?, original: FailedDictation)
    }

    /// Итог попытки для судьбы WAV и слота повтора.
    private enum Outcome {
        case succeeded          // текст в истории (вставка могла и не пройти)
        case failed(String)     // ошибка ДО записи в историю — есть что повторить
        case abandoned          // отмена/устаревшая задача — повторять нечего
    }

    init() {
        recorder.onLevel = { [weak self] level in
            self?.audioLevel = level
        }
        // Смена аудиоустройства во время записи: мягко завершаем с тем, что есть.
        recorder.onConfigurationChange = { [weak self] in
            guard let self, self.state.isRecording else { return }
            self.finishRecording()
        }
    }

    // MARK: - Действия хоткеев

    func toggle() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            finishRecording()
        case .transcribing:
            break // идёт запрос — отмена через Esc
        }
    }

    /// Push-to-talk: зажатие начинает запись (только из покоя — повторные
    /// авторепиты keyDown во время записи игнорируются)…
    func pushToTalkDown() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording, .transcribing:
            break
        }
    }

    /// …отпускание — завершает и отправляет на распознавание. Случайное
    /// короткое нажатие отсеет порог `DictationGate.minDuration`.
    func pushToTalkUp() {
        guard state.isRecording else { return }
        finishRecording()
    }

    func cancel() {
        switch state {
        case .recording:
            recorder.cancelAndDelete()
            SoundPlayer.play(.cancel)
            transition(to: .idle)
        case .transcribing:
            transcriptionTask?.cancel()
            transcriptionTask = nil
            SoundPlayer.play(.cancel)
            transition(to: .idle)
        case .idle, .error:
            break
        }
    }

    func pasteLastTranscription() {
        // Во время записи/распознавания вставка ломала бы автомат — игнорируем.
        switch state {
        case .recording, .transcribing:
            return
        case .idle, .error:
            break
        }
        guard let text = history.lastText else {
            showError(L("error.historyEmpty"))
            return
        }
        Task {
            do {
                try await Paster.paste(text, restoreClipboard: settings.restoreClipboard)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// «Повторить неудачную диктовку» из меню-бара: та же запись уходит на
    /// распознавание текущим сервисом, в обход гейта тишины (пользователь
    /// явно просит распознать). Esc во время повтора возвращает запись в слот.
    func retryLastFailedDictation() {
        switch state {
        case .recording, .transcribing:
            return
        case .idle, .error:
            break
        }
        guard let failed = lastFailedDictation else { return }
        guard FileManager.default.fileExists(atPath: failed.audio.url.path) else {
            lastFailedDictation = nil
            showError(L("error.retryUnavailable"))
            return
        }
        lastFailedDictation = nil   // слот «взят»; вернётся при неудаче или отмене
        // Меню статус-бара не активирует DOKA: впереди остаётся приложение,
        // где был курсор, — туда и вставим, если оно не сменится.
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        transition(to: .transcribing)
        let gen = generation
        transcriptionTask = Task {
            await transcribeAndPaste(failed.audio,
                                     source: .retry(targetPID: target, original: failed),
                                     generation: gen)
        }
    }

    /// Забыть слот повтора вместе с его WAV (выход из приложения).
    func discardFailedDictation() {
        guard let failed = lastFailedDictation else { return }
        lastFailedDictation = nil
        Self.removeFile(failed.audio.url)
    }

    // MARK: - Цикл записи

    private func startRecording() {
        let permissions = PermissionsManager.shared
        permissions.refresh()
        guard permissions.micAuthorized, permissions.axTrusted else {
            onNeedsOnboarding?()
            return
        }
        guard settings.isServiceReady else {
            // Локальный сервис не готов = модель не скачана; сетевой — нет ключа.
            showError(settings.isLocalService
                ? L("error.localModelMissing")
                : L("error.noAPIKey"))
            onNeedsOnboarding?()
            return
        }

        // Диктовка важнее анализа. На маке с небольшой ОЗУ языковая модель
        // анализа (до 5 ГБ) и речевая модель вместе уводят систему в своп,
        // и диктовка — та, ради которой приложение и запускают, — начинает
        // тормозить. Гасим анализ ДО старта записи и объясняем, почему.
        // Сетевой сервис распознавания ОЗУ не держит: там анализ не трогаем.
        if settings.isLocalService && LLMModelSpec.isLowMemoryMac {
            AnalysisController.shared.cancelIfRunning(message: L("analysis.interruptedByDictation"))
            LocalEngineManager.shared.unloadLLM()
        }

        do {
            _ = try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        if settings.micAutoBoost {
            micBooster.beginBoost()
        }
        SoundPlayer.play(.recordStart)
        transition(to: .recording(startedAt: Date()))
    }

    private func finishRecording() {
        guard state.isRecording else { return }
        guard let result = recorder.stop() else {
            showError(L("error.saveRecordingFailed"))
            return
        }
        SoundPlayer.play(.recordStop)

        // Имя микрофона для метаданных истории — независимо от уже остановленного движка.
        let audio = RecordedDictation(url: result.url, duration: result.duration,
                                      speechDuration: result.speechDuration,
                                      microphone: recorder.currentInputDeviceName)

        switch DictationGate.decide(duration: audio.duration,
                                    speechDuration: audio.speechDuration,
                                    speechGateEnabled: settings.skipSilentRecordings) {
        case .tooShort:
            Self.removeFile(audio.url)
            transition(to: .idle)
            return
        case .noSpeech:
            // Ни API, ни история, ни статистика: не платим за тишину и не ловим
            // галлюцинации Whisper. Лог — для калибровки порога.
            NSLog("DOKA: гейт тишины — запись %.2f с, речи %.2f с, на распознавание не отправлена",
                  audio.duration, audio.speechDuration)
            if DictationGate.isRetryable(duration: audio.duration) {
                // Возможно, просто тихий голос: запись можно распознать всё равно.
                storeFailed(audio, message: L("error.noSpeech"), gated: true)
            } else {
                Self.removeFile(audio.url)
            }
            showError(L("error.noSpeech"), sound: .cancel)
            return
        case .transcribe:
            break
        }

        transition(to: .transcribing)
        let gen = generation
        transcriptionTask = Task {
            await transcribeAndPaste(audio, source: .live, generation: gen)
        }
    }

    private func transcribeAndPaste(_ audio: RecordedDictation, source: DictationSource,
                                    generation gen: Int) async {
        let url = audio.url
        // Судьба WAV и слота решается одним местом по итогу попытки. Сам
        // `settle` автомат не трогает: `failed` выставляется только при
        // `generation == gen`, так что устаревшая задача слот не перезапишет.
        var outcome = Outcome.abandoned
        defer { settle(audio, source: source, outcome: outcome) }

        // Маршрут распознавания: локальный движок или сетевой клиент.
        let route: ServiceRoute
        do {
            route = try settings.resolveRoute()
        } catch {
            if generation == gen {
                outcome = .failed(error.localizedDescription)
                showError(error.localizedDescription)
            }
            return
        }
        let language = settings.language
        let providerRaw = settings.providerTagForHistory
        let modelTag = route.modelTag

        // Копия без тишины — только для отправки: история, статистика и m4a
        // работают с оригиналом. Обрезка — CPU-работа вне главного потока.
        var uploadURL = url
        if settings.silenceRemoval {
            let trimmed = await Task.detached(priority: .userInitiated) {
                SilenceRemover.process(url)
            }.value
            guard generation == gen else {
                if let trimmed { try? FileManager.default.removeItem(at: trimmed) }
                return
            }
            if let trimmed { uploadURL = trimmed }
        }
        defer {
            if uploadURL != url { try? FileManager.default.removeItem(at: uploadURL) }
        }

        do {
            let started = Date()
            let raw: String
            switch route {
            case .local(let localModel):
                // Загрузка движка — тоже await: после неё те же права на автомат,
                // что и после любого другого await (проверка generation ниже).
                let engine = try await LocalEngineManager.shared.engine(for: localModel)
                guard generation == gen else { return }
                raw = try await engine.transcribeDictation(
                    wavURL: uploadURL,
                    language: language == "auto" ? nil : language
                )
                LocalEngineManager.shared.touch()
            case .remote(let apiKey, let config):
                raw = try await client.transcribe(
                    fileURL: uploadURL,
                    language: language == "auto" ? nil : language,
                    apiKey: apiKey,
                    config: config
                )
            }
            let transcriptionTime = Date().timeIntervalSince(started)
            guard generation == gen else { return }   // отменено пользователем
            let text = ReplacementEngine.apply(raw, rules: settings.replacements)
            // Кодируем аудио в m4a ДО выхода (settle уберёт исходный WAV). id фиксируем заранее,
            // чтобы имя файла и запись истории гарантированно совпадали. Если сохранение аудио
            // выключено — кодирование пропускаем целиком, и вставка не ждёт его (быстрее).
            let recordID = UUID()
            let audioName = settings.saveAudio
                ? await AudioStore.shared.encode(wavURL: url, recordID: recordID)
                : nil
            // Отмена могла произойти во время кодирования (ещё один await) — устаревшая
            // задача не должна писать в историю и вставлять текст. Закодированный файл убираем.
            guard generation == gen else {
                if let audioName { AudioStore.shared.removeFile(named: audioName) }
                return
            }
            history.add(id: recordID, text: text, duration: audio.duration, language: language,
                        speechDuration: audio.speechDuration, model: modelTag, provider: providerRaw,
                        microphone: audio.microphone, transcriptionTime: transcriptionTime,
                        audioFileName: audioName)
            stats.record(text: text, duration: audio.duration, speechDuration: audio.speechDuration)
            // Текст уже в истории: дальше повторять нечего, даже если вставка не пройдёт.
            outcome = .succeeded

            // Повтор идёт секунды — за это время пользователь мог уйти в другое
            // приложение. Вставлять туда нельзя: только буфер и сообщение.
            if case .retry(let targetPID, _) = source, !Self.isFrontmost(targetPID) {
                ClipboardManager.setString(text)
                showError(L("dictation.retry.copied"), sound: .recordStop)
                return
            }
            do {
                try await Paster.paste(text, restoreClipboard: settings.restoreClipboard)
                guard generation == gen else { return }
                transition(to: .idle)
            } catch {
                guard generation == gen else { return }
                // Текст уже в буфере обмена и в истории — сообщаем и живём дальше.
                showError(error.localizedDescription)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == gen else { return }
            outcome = .failed(error.localizedDescription)
            showError(error.localizedDescription)
        }
    }

    // MARK: - Слот повтора

    /// Судьба записи по итогу попытки. Автомат не трогает — только файлы и слот.
    private func settle(_ audio: RecordedDictation, source: DictationSource, outcome: Outcome) {
        switch outcome {
        case .succeeded:
            Self.removeFile(audio.url)
            // Пользователь продиктовал заново — старый повтор вставил бы
            // неактуальный текст.
            if case .live = source { discardFailedDictation() }
        case .failed(let message):
            storeFailed(audio, message: message)
        case .abandoned:
            switch source {
            case .live:
                // Отмена Esc — намерение выбросить запись.
                Self.removeFile(audio.url)
            case .retry(_, let original):
                // Отменили повтор, а не саму запись: вернуть её в слот. Если
                // слот уже занят более свежей неудачей — файл больше не нужен.
                if lastFailedDictation == nil {
                    lastFailedDictation = original
                } else if lastFailedDictation?.audio.url != audio.url {
                    Self.removeFile(audio.url)
                }
            }
        }
    }

    /// Положить запись в слот; прежняя запись слота (если это другой файл) удаляется.
    /// Исключение: отсеянная гейтом «возможно, тишина» не вытесняет настоящую
    /// неудачу — иначе случайное нажатие хоткея после сбоя сети стёрло бы
    /// реальную диктовку. Такая тишина просто выбрасывается.
    private func storeFailed(_ audio: RecordedDictation, message: String, gated: Bool = false) {
        if gated, let old = lastFailedDictation, !old.gated, old.audio.url != audio.url {
            Self.removeFile(audio.url)
            return
        }
        if let old = lastFailedDictation, old.audio.url != audio.url {
            Self.removeFile(old.audio.url)
        }
        lastFailedDictation = FailedDictation(audio: audio, failedAt: Date(), message: message,
                                              gated: gated)
    }

    private static func isFrontmost(_ pid: pid_t?) -> Bool {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Сироты временных файлов прошлых запусков: слот повтора живёт в памяти и
    /// теряется при выходе или крэше, крэш посреди распознавания оставляет
    /// WAV/обрезки/тела запросов. На старте файловой работы в полёте нет, а
    /// фильтр по дате изменения не даёт тронуть то, что создаётся сейчас.
    nonisolated static func sweepOrphanedTempFiles(before launch: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                      includingPropertiesForKeys: keys) else { return }
        for url in items where url.lastPathComponent.hasPrefix("doka-")
            && ["wav", "tmp"].contains(url.pathExtension) {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            if (modified ?? .distantPast) < launch {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Состояния

    private func transition(to newState: State) {
        generation += 1
        errorDismissTask?.cancel()
        errorDismissTask = nil
        // Уход из записи любым путём (стоп, отмена, ошибка, смена устройства) —
        // громкость микрофона возвращается к прежней. Без буста — no-op.
        if state.isRecording, !newState.isRecording {
            micBooster.endBoost()
        }
        state = newState
        audioLevel = 0
        // Esc активен при записи и при распознавании (отмена запроса).
        hotkeys?.setEscapeEnabled(newState.isRecording || newState == .transcribing)

        switch newState {
        case .idle:
            panelController?.hide()
        case .recording, .transcribing, .error:
            panelController?.show()
        }
    }

    /// Сообщение на панели (канал `.error` — он же для информативных сообщений,
    /// как у `error.secureInput`). Звук — по смыслу: тишине и «скопировано»
    /// не нужен тревожный Basso.
    private func showError(_ message: String, sound: SoundPlayer.Event = .error) {
        SoundPlayer.play(sound)
        transition(to: .error(message: message))
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            if case .error = self?.state {
                self?.transition(to: .idle)
            }
        }
    }
}
