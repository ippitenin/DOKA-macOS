import AVFoundation
import Combine
import QuartzCore

/// Окно «Тренировка» (эксперимент «Губы»): беззвучные фразы на экране.
///
/// Человек проговаривает показанную фразу одними губами, дубль камеры
/// сохраняется парой с ТОЧНЫМ текстом — звук беззвучную пару не разметит.
/// Путь пары тот же, что у диктовки (`LipCapture` → `LipDataStore`), но мимо
/// `DictationController`: гейт тишины и распознавание здесь не нужны. Звук
/// всё равно пишется — своим `AudioRecorder`: он даёт шкалу WAV для сшивки
/// и AAC-дорожку клипа (без неё препроцессинг WISLIP виснет), а по нему
/// `LipTrainingCheck` ловит фразу, сказанную вслух.
///
/// Прошлая пара фиксируется не сразу, а при старте следующей фразы или
/// закрытии окна: до этого «Переписать прошлую» — просто выброс. Этот учёт
/// (очередь, отложенная фраза, обработка, прошлая) — чистый
/// `LipTrainingSession`; контроллер держит камеру, микрофон и таймеры.
@MainActor
final class LipTrainingController: ObservableObject {
    static let shared = LipTrainingController()

    enum Phase: Equatable {
        /// Пробел — начать.
        case idle
        /// Камера и микрофон стартовали, губ ещё не видно.
        case warming
        /// «Говорите губами»: губы в кадре, идёт фраза.
        case recording(since: Date)

        var isActive: Bool { self != .idle }
    }

    /// Сообщение под фразой о том, почему фразы нет.
    enum Notice: Equatable {
        case tooShort
        case voiced
        case notReady
        case interrupted
        case dictationActive
        case cameraPermission
        case microphonePermission
        case noRoom
        case cameraUnavailable
        case microphoneFailed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: Notice?
    @Published private(set) var session = LipTrainingSession()
    /// Фразы ещё грузятся (история, уже записанное).
    @Published private(set) var isLoading = false

    /// Фраза на экране; nil — фразы кончились или ещё грузятся.
    var current: LipTrainingPhrase? { session.current }
    var last: LipTrainingSession.Last? { session.last }
    var sessionSaved: Int { session.saved }
    var canRewrite: Bool { phase == .idle && session.canRewrite }

    private let recorder = AudioRecorder()
    private var activeTake: LipTake?
    /// Хост-время подсказки «Говорите» — начало фразы на шкале WAV.
    private var cueHost: TimeInterval?
    private var autoStop: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Губы впервые в кадре — сигнал «Говорите».
        LipCapture.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.cameraPhaseChanged(phase) }
            .store(in: &cancellables)
        LipDataStore.shared.outcomes
            .receive(on: RunLoop.main)
            .sink { [weak self] outcome in self?.handle(outcome) }
            .store(in: &cancellables)
        // Смена микрофона посреди фразы: запись с двух устройств не сшить.
        recorder.onConfigurationChange = { [weak self] in
            guard let self, self.phase.isActive else { return }
            self.cancel(notice: .microphoneFailed)
        }
    }

    // MARK: - Сеанс

    /// Окно открыто: собрать очередь фраз и подготовить камеру.
    func beginSession() {
        guard session.open() else { return }
        notice = nil
        LipCapture.shared.prepareIfEnabled(for: .training)
        loadPhrases()
    }

    /// Окно закрыто: идущая фраза выбрасывается, отложенная — фиксируется.
    func endSession() {
        guard session.close() else { return }
        loadTask?.cancel()
        if phase.isActive { cancel(notice: nil) }
        commitHeld()
    }

    /// Выход приложения: фиксация отложенной пары синхронна (жёсткая ссылка
    /// на WAV), заказ допишет очередь стора — её ждёт
    /// `LipDataStore.prepareForTermination`, поэтому звать раньше него.
    func prepareForTermination() {
        if phase.isActive { cancel(notice: nil) }
        commitHeld()
    }

    private func loadPhrases() {
        isLoading = true
        session.reload(.empty)
        let history = LipTrainingPhrases.fromHistory(HistoryStore.shared.records.map(\.text))
            .map { LipTrainingPhrase(text: $0, origin: .history) }
        let builtin = LipTrainingPhrases.builtin()
        loadTask = Task { [weak self] in
            let done = await LipDataStore.shared.trainingTexts()
            guard let self, !Task.isCancelled, self.session.isOpen else { return }
            // Плюс фразы, записанные в этом процессе, но ещё не дошедшие до диска.
            let doneKeys = Set(done.map(LipTrainingPhrases.normalize)).union(self.session.pendingKeys)
            self.session.reload(LipTrainingQueue(
                pools: [history,
                        builtin.filter { $0.origin == .work },
                        builtin.filter { $0.origin == .everyday },
                        builtin.filter { $0.origin == .mixed }],
                done: doneKeys, seed: UInt64.random(in: 0...UInt64.max)))
            self.isLoading = false
        }
    }

    // MARK: - Действия

    /// Пробел: начать фразу или закончить её.
    func toggle() {
        switch phase {
        case .idle: start()
        case .warming, .recording: stop()
        }
    }

    func start() {
        guard session.isOpen, phase == .idle, let phrase = current else { return }
        guard !DictationController.isActive else {
            notice = .dictationActive
            return
        }
        let permissions = PermissionsManager.shared
        permissions.refresh()
        guard permissions.micAuthorized else {
            notice = .microphonePermission
            return
        }
        // Следующая фраза — значит, прошлую уже не переписывают.
        commitHeld()
        guard let take = LipCapture.shared.beginTake(for: .training) else {
            notice = !permissions.cameraAuthorized ? .cameraPermission
                : !LipCapture.shared.hasRoom ? .noRoom : .cameraUnavailable
            return
        }
        do {
            _ = try recorder.start(quiet: false)
        } catch {
            NSLog("DOKA: тренировка — микрофон не стартовал: %@", error.localizedDescription)
            LipCapture.shared.abortTake(take)
            notice = .microphoneFailed
            return
        }
        activeTake = take
        cueHost = nil
        notice = nil
        phase = .warming
        SoundPlayer.play(.recordStart)
        NSLog("DOKA: тренировка — фраза «%@» (%@), дубль %@", phrase.text, phrase.origin.rawValue,
              take.id.uuidString)
        // Камера могла уже видеть губы (фаза публикуется только на смене).
        cameraPhaseChanged(LipCapture.shared.phase)
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LipTrainingCheck.maxDuration))
            guard !Task.isCancelled, let self, self.activeTake == take else { return }
            self.stop()
        }
    }

    /// Стоп: проверка звука, затем фраза откладывается до следующей.
    func stop() {
        guard phase.isActive, let take = activeTake, let phrase = current else { return }
        let reachedCue = cueHost != nil
        autoStop?.cancel()
        cueTask?.cancel()
        cueTask = nil
        activeTake = nil
        phase = .idle
        guard let result = recorder.stop() else {
            LipCapture.shared.abortTake(take)
            notice = .microphoneFailed
            return
        }
        LipCapture.shared.stopCamera()
        SoundPlayer.play(.recordStop)

        // Губ так и не дождались — фразу не начинали.
        let check = reachedCue
            ? LipTrainingCheck.decide(duration: result.duration, speechSeconds: result.speechDuration)
            : nil
        NSLog("DOKA: тренировка — дубль %@: %.2f с, речь %.2f с, тихо %.2f с, решение %@",
              take.id.uuidString, result.duration, result.speechDuration, result.quietSpeechDuration,
              check.map { String(describing: $0) } ?? "без подсказки")
        guard check == .keep else {
            LipCapture.shared.discard(take)
            Self.removeFile(result.url)
            switch check {
            case .tooShort: notice = .tooShort
            case .voiced: notice = .voiced
            default: notice = .notReady
            }
            return
        }

        let onset = LipTrainingCheck.onset(cueHost: cueHost, timing: result.timing)
        let timing = result.timing.map {
            RecordingTiming(hostStart: $0.hostStart, inputLatency: $0.inputLatency, speechOnset: onset,
                            maxClockDrift: $0.maxClockDrift)
        }
        let audio = RecordedDictation(url: result.url, duration: result.duration,
                                      speechDuration: result.speechDuration,
                                      microphone: recorder.currentInputDeviceName,
                                      quiet: false, quietSpeechDuration: result.quietSpeechDuration,
                                      timing: timing, lipTake: take)
        session.hold(.init(take: take, audio: audio, phrase: phrase))
        notice = nil
    }

    /// Esc во время фразы: дубль выбрасывается, фраза остаётся.
    func cancel() {
        guard phase.isActive else { return }
        cancel(notice: nil)
        SoundPlayer.play(.cancel)
    }

    /// «Пропустить» — фраза уходит в конец очереди.
    func skip() {
        guard phase == .idle else { return }
        session.skip()
        notice = nil
    }

    /// «Переписать прошлую» (R): отложенная пара выбрасывается, её фраза
    /// снова на экране.
    func rewritePrevious() {
        guard phase == .idle, let held = session.rewrite() else { return }
        LipCapture.shared.discard(held.take)
        Self.removeFile(held.audio.url)
        notice = nil
    }

    /// Хоткей диктовки посреди фразы: диктовка важнее, камера — ей.
    /// Отложенная пара не трогается.
    func interruptForDictation() {
        guard phase.isActive else { return }
        cancel(notice: .interrupted)
    }

    private func cancel(notice: Notice?) {
        autoStop?.cancel()
        cueTask?.cancel()
        cueTask = nil
        let take = activeTake
        activeTake = nil
        phase = .idle
        recorder.cancelAndDelete()
        LipCapture.shared.abortTake(take)
        self.notice = notice
    }

    /// Подсказка — не на первом кадре с губами, а чуть позже: первые кадры
    /// холодной камеры уходят на прогрев экспозиции (`LipSync.warmupMin`), и
    /// фраза, начатая сразу, считалась бы «началом без видео».
    static let cueDelay: TimeInterval = 0.3

    private func cameraPhaseChanged(_ cameraPhase: LipMirrorPhase) {
        guard phase == .warming, let take = activeTake, cameraPhase == .face, cueTask == nil else { return }
        cueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cueDelay))
            guard !Task.isCancelled, let self else { return }
            self.cueTask = nil
            guard self.phase == .warming, self.activeTake == take else { return }
            self.cueHost = CACurrentMediaTime()
            self.phase = .recording(since: Date())
        }
    }

    // MARK: - Фиксация и исходы

    private func commitHeld() {
        // Фраза встаёт в обработку ДО фиксации: исход сбоя её найдёт.
        guard let held = session.releaseHeld() else { return }
        let caption = LipCaption.training(phrase: held.phrase.text, origin: held.phrase.origin.rawValue)
        // Жёсткая ссылка на WAV берётся синхронно — затем исходник удаляется.
        LipDataStore.shared.commit(held.take, caption: caption, audio: held.audio)
        Self.removeFile(held.audio.url)
    }

    private func handle(_ outcome: LipTakeOutcome) {
        guard session.apply(outcome) else { return }
        LipDataStore.shared.refreshSummary()
    }

    private static func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension LipTrainingController.Notice {
    /// Сообщение под фразой.
    var text: String {
        switch self {
        case .tooShort: return L("training.notice.tooShort")
        case .voiced: return L("training.notice.voiced")
        case .notReady: return L("training.notice.notReady")
        case .interrupted: return L("training.notice.interrupted")
        case .dictationActive: return L("training.notice.dictationActive")
        case .cameraPermission: return L("training.notice.cameraPermission")
        case .microphonePermission: return L("training.notice.microphonePermission")
        case .noRoom: return L("training.notice.noRoom")
        case .cameraUnavailable: return L("training.notice.cameraUnavailable")
        case .microphoneFailed: return L("training.notice.microphoneFailed")
        }
    }
}
