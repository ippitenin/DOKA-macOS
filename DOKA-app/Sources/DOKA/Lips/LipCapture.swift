import AVFoundation
import Combine
import QuartzCore

/// Состояние камеры для зеркала губ.
enum LipMirrorPhase: Equatable {
    case idle
    /// Камера включается, кадров ещё нет.
    case warming
    case face
    case noFace
    /// Кадров нет — камеру забрали или она отключилась.
    case unavailable
}

/// Камера эксперимента «Губы»: снимает лицо во время диктовки.
///
/// Камера работает ТОЛЬКО на время записи: `beginTake` при старте диктовки,
/// `stopCamera` при уходе из записи (хук в `DictationController.transition`).
/// Без разрешения, без камеры или при сбое дубль просто не получается —
/// диктовка от камеры не зависит никогда. Разрешение запрашивается только
/// в разделе «Губы»: `beginTake` при статусе «не спрашивали» дубля не
/// начинает, иначе системный запрос всплыл бы посреди диктовки.
@MainActor
final class LipCapture: ObservableObject {
    static let shared = LipCapture()

    let engine = LipCameraEngine()
    /// Имя камеры — для раздела «Губы»; nil — камеры нет или не настроена.
    @Published private(set) var cameraName: String?
    /// Идёт дубль (камера снимает) — для зеркала.
    @Published private(set) var activeTake: LipTake?
    /// Состояние для зеркала; публикуется только на смене, не покадрово.
    @Published private(set) var phase: LipMirrorPhase = .idle
    /// Кадры зеркала: картинка и маска одного кадра камеры. Зеркало рисует
    /// само, без перерисовки SwiftUI на каждый кадр.
    ///
    /// В буфер камеры НЕ рисуем — рендер только в свой приёмник: иначе маска
    /// и отражение попали бы в `raw.mp4`, а за ним в `clip.mp4`.
    var mirrorFeed: LipMirrorFeed { engine.mirrorFeed }

    private var takeStartedAt = Date.distantPast
    private var lastSampleAt: Date?
    private var lastFaceAt: Date?
    private var phaseTimer: Timer?
    /// Лица нет дольше — «Лица не видно».
    private static let faceLostAfter = LipMirrorCamera.lostAfter
    /// Кадров нет дольше — «Камера недоступна».
    private static let cameraLostAfter: TimeInterval = 2.5

    /// Свободное место — кэш, опрашиваемый фоном: старт диктовки его только читает.
    private let freeSpace = LipFreeSpace()

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let settings = SettingsStore.shared
        // Камера дописала сырьё дубля — событие для хранилища пар.
        // Оба события приходят из одной последовательной видео-очереди и на
        // главный поток — через FIFO `DispatchQueue.main`: «записан» всегда
        // раньше «выброшен», и хранилище не держит id выброшенных дублей.
        engine.onTakeCaptured = { take in
            DispatchQueue.main.async { MainActor.assumeIsolated { LipDataStore.shared.captureFinished(take) } }
        }
        engine.onTakeDiscarded = { take in
            DispatchQueue.main.async { MainActor.assumeIsolated { LipDataStore.shared.forget(take) } }
        }
        engine.onFace = { sample in
            Task { @MainActor in LipCapture.shared.handleFace(sample) }
        }
        // Включили сбор или выдали доступ — настроить сессию заранее, чтобы
        // старт дубля был только `startRunning`. @Published шлёт значение до
        // записи в свойство — отсюда переход на следующий цикл.
        Publishers.CombineLatest3(settings.$lipsExperiment, settings.$lipsLearn,
                                  PermissionsManager.shared.$cameraAuthorized)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.prepareIfEnabled() }
            .store(in: &cancellables)
    }

    /// Настроить сессию, если сбор включён и доступ есть. Камера при этом не
    /// включается (индикатор не горит). Заодно прогрев зеркала — один раз за
    /// процесс, повторные вызовы его не повторяют.
    func prepareIfEnabled() {
        guard SettingsStore.shared.lipsCaptureEnabled,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        freeSpace.refresh()
        configure()
        engine.prewarmMirror()
    }

    private func configure() {
        engine.configure { [weak self] name in
            Task { @MainActor in self?.cameraName = name }
        }
    }

    /// Начать дубль. nil — сбор выключен, нет доступа или места; диктовка
    /// идёт как обычно.
    func beginTake() -> LipTake? {
        guard SettingsStore.shared.lipsCaptureEnabled,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return nil }
        guard freeSpace.hasRoom else {
            NSLog("DOKA: губы — мало места на диске, дубль не начат")
            return nil
        }
        let take = LipTake(id: UUID())
        do {
            try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        } catch {
            NSLog("DOKA: губы — папка дубля не создана: %@", error.localizedDescription)
            return nil
        }
        configure()
        let recorder = LipTakeRecorder(take: take, acceptFromHost: CACurrentMediaTime(),
                                       queue: engine.videoQueue)
        // Ящик — раньше движка: первый кадр нового дубля не должен застать
        // ящик на прошлом дубле.
        mirrorFeed.begin(take: take.id)
        engine.begin(recorder)
        activeTake = take
        takeStartedAt = Date()
        lastSampleAt = nil
        lastFaceAt = nil
        phase = .warming
        startPhaseTimer()
        return take
    }

    /// Остановить камеру (уход из записи любым путём). Дубль дописывается
    /// фоном; его судьбу решает `DictationController.settle` или `discard`.
    func stopCamera() {
        guard activeTake != nil else { return }
        activeTake = nil
        stopPhaseTimer()
        engine.end()
        mirrorFeed.end()
        // Дубль занял место — обновить кэш к следующей диктовке.
        freeSpace.refresh()
    }

    /// Выбросить дубль; nil — дубля не было (сбор выключен или камера не
    /// взлетела), делать нечего.
    func discard(_ take: LipTake?) {
        guard let take else { return }
        engine.discard(take)
    }

    func shutdown() {
        activeTake = nil
        stopPhaseTimer()
        engine.shutdown()
    }

    // MARK: - Фаза для зеркала

    private func handleFace(_ sample: LipFaceSample) {
        guard activeTake != nil else { return }
        let now = Date()
        lastSampleAt = now
        if sample.box != nil { lastFaceAt = now }
        updatePhase(now: now)
    }

    private func updatePhase(now: Date) {
        guard activeTake != nil else { return }
        let next: LipMirrorPhase
        if let last = lastSampleAt {
            if now.timeIntervalSince(last) > Self.cameraLostAfter {
                next = .unavailable
            } else if let face = lastFaceAt, now.timeIntervalSince(face) <= Self.faceLostAfter {
                next = .face
            } else if now.timeIntervalSince(lastFaceAt ?? takeStartedAt) > Self.faceLostAfter {
                next = .noFace
            } else {
                next = phase == .warming ? .warming : .noFace
            }
        } else {
            next = now.timeIntervalSince(takeStartedAt) > Self.cameraLostAfter ? .unavailable : .warming
        }
        if next != phase { phase = next }
    }

    private func startPhaseTimer() {
        stopPhaseTimer()
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in LipCapture.shared.updatePhase(now: Date()) }
        }
    }

    private func stopPhaseTimer() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        phase = .idle
    }
}
