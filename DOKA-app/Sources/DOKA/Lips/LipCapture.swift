import AVFoundation
import Combine
import QuartzCore
import os

/// Камера-кандидат для губ (чистая модель выбора — проверяется тестами).
struct LipCameraCandidate {
    let isBuiltIn: Bool
    let isSuspended: Bool
}

enum LipCameraChooser {
    /// Индекс камеры: встроенная первой, затем любая; спящие не годятся.
    static func pick(_ candidates: [LipCameraCandidate]) -> Int? {
        let awake = candidates.indices.filter { !candidates[$0].isSuspended }
        return awake.first { candidates[$0].isBuiltIn } ?? awake.first
    }
}

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
    /// Общий слой превью для зеркала. Создаётся ОДИН раз, ДО конфигурации
    /// сессии: слой, добавленный в работающую сессию, её переконфигурирует —
    /// разрыв кадров и скачок экспозиции, который трекер лиц WISLIP примет
    /// за «смену сцены».
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    /// Имя камеры — для раздела «Губы»; nil — камеры нет или не настроена.
    @Published private(set) var cameraName: String?
    /// Идёт дубль (камера снимает) — для зеркала.
    @Published private(set) var activeTake: LipTake?
    /// Состояние для зеркала; публикуется только на смене, не покадрово.
    @Published private(set) var phase: LipMirrorPhase = .idle
    /// Лицо и размер кадра для зеркала, ~15 раз в секунду. Не @Published:
    /// зеркало двигает слои само, без перерисовки SwiftUI на каждый кадр.
    var onMouth: ((LipFaceSample, CGSize) -> Void)?

    private var takeStartedAt = Date.distantPast
    private var lastSampleAt: Date?
    private var lastFaceAt: Date?
    private var phaseTimer: Timer?
    /// Лица нет дольше — «Лица не видно».
    private static let faceLostAfter: TimeInterval = 0.5
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
        engine.onFace = { sample, size in
            Task { @MainActor in LipCapture.shared.handleFace(sample, size: size) }
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
    /// включается (индикатор не горит).
    func prepareIfEnabled() {
        guard SettingsStore.shared.lipsCaptureEnabled,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        freeSpace.refresh()
        configure()
    }

    private func configure() {
        let layer: AVCaptureVideoPreviewLayer
        if let previewLayer {
            layer = previewLayer
        } else {
            layer = AVCaptureVideoPreviewLayer(session: engine.session)
            layer.videoGravity = .resize
            previewLayer = layer
        }
        engine.configure(previewLayer: layer) { [weak self] name in
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
        // Дубль занял место — обновить кэш к следующей диктовке.
        freeSpace.refresh()
    }

    func discard(_ take: LipTake) {
        engine.discard(take)
    }

    func shutdown() {
        activeTake = nil
        stopPhaseTimer()
        engine.shutdown()
    }

    // MARK: - Фаза для зеркала

    private func handleFace(_ sample: LipFaceSample, size: CGSize) {
        guard activeTake != nil else { return }
        let now = Date()
        lastSampleAt = now
        if sample.box != nil { lastFaceAt = now }
        updatePhase(now: now)
        onMouth?(sample, size)
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

/// Сессия камеры и маршрутизация кадров. Три последовательные очереди:
/// `sessionQueue` — настройка, старт и стоп (`startRunning` блокирует на
/// сотни мс, главному потоку этого нельзя); `videoQueue` — кадры и текущий
/// дубль; `visionQueue` — поиск лица и ритм журнала.
///
/// Vision идёт на каждом кадре, который застал его свободным; в журнал лица
/// результат попадает по `LipJournalCadence` (~15 Гц, как раньше).
final class LipCameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "com.pitenin.doka.lips.video", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "com.pitenin.doka.lips.session", qos: .userInitiated)
    /// Не `private`: тесты дожидаются на ней конца Vision по кадру (и снятия
    /// флага занятости), чтобы подать следующий кадр свободному Vision.
    let visionQueue = DispatchQueue(label: "com.pitenin.doka.lips.vision", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let detector: any LipFaceDetecting
    /// Vision занят кадром. Флаг под замком, а не состояние `videoQueue`:
    /// ставит его кадр на `videoQueue`, а снимает сам блок `visionQueue` (в
    /// `defer` — и при ошибке Vision), без перехода на `videoQueue` на
    /// каждом кадре. Флаг, а не сам замок: unfair lock отпускает только
    /// поток, который его взял.
    private let visionGate = OSAllocatedUnfairLock(initialState: false)

    /// Результат Vision для зеркала: образец лица и размер кадра. Зовётся на
    /// `videoQueue` на ритме журнала — не чаще ~15 раз в секунду.
    var onFace: (@Sendable (LipFaceSample, CGSize) -> Void)?
    /// Сырьё дубля дописано (не выброшенного). Зовётся на `videoQueue`.
    var onTakeCaptured: (@Sendable (LipTake) -> Void)?
    /// Выброшен дубль, о котором уже сообщили `onTakeCaptured` (и только
    /// такой). Зовётся на `videoQueue` — строго после `onTakeCaptured`.
    var onTakeDiscarded: (@Sendable (LipTake) -> Void)?

    // Состояние sessionQueue.
    private var device: AVCaptureDevice?
    private var configured = false
    private var wantRunning = false
    private var format: (format: AVCaptureDevice.Format, frameDuration: CMTime)?

    // Состояние videoQueue.
    private var current: LipTakeRecorder?
    private var recorders: [UUID: LipTakeRecorder] = [:]
    private var frameStats = FrameStats()

    // Состояние visionQueue.
    private var cadence = LipJournalCadence()
    private var visionStats = VisionStats()

    private var observers: [NSObjectProtocol] = []

    /// `detector` — шов для тестов. Конструктор не создаёт ни Vision, ни
    /// Metal: `LipFaceTracker` заводит запрос только на первом кадре.
    init(detector: any LipFaceDetecting = LipFaceTracker()) {
        self.detector = detector
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            NSLog("DOKA: губы — ошибка сессии камеры: %@", error?.localizedDescription ?? "?")
            self?.handleCameraLoss()
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                            object: nil, queue: nil) { [weak self] note in
            guard let self, let gone = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                guard gone.uniqueID == self.device?.uniqueID else { return }
                NSLog("DOKA: губы — камера отключена")
                self.handleCameraLoss()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Настройка

    /// Найти камеру и настроить сессию (без запуска). Повторный вызов на
    /// настроенной сессии ничего не меняет. `completion(имя камеры | nil)`.
    func configure(previewLayer: AVCaptureVideoPreviewLayer, completion: @escaping @Sendable (String?) -> Void) {
        sessionQueue.async { [self] in
            // Настроенная сессия переиспользуется, пока её камера не уснула:
            // у MacBook с закрытой крышкой встроенная камера остаётся в
            // списке спящей, и `wasDisconnected` об этом не сообщает.
            if configured, let device, !device.isSuspended {
                completion(device.localizedName)
                return
            }
            guard let device = Self.pickDevice(), let chosen = Self.pickFormat(device) else {
                NSLog("DOKA: губы — подходящей камеры нет")
                completion(nil)
                return
            }
            // Center Stage двигает и масштабирует кадр сам: фиксированный кроп
            // дубля и трекер лиц WISLIP этого не переживут.
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false

            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotAdd }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                NSLog("DOKA: губы — камеру не подключить: %@", error.localizedDescription)
                completion(nil)
                return
            }
            if !session.outputs.contains(output) {
                // 420v — родной формат камеры: без копий его принимают и
                // кодер, и Vision.
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            // В файл — без зеркала (как видит камера); зеркалит только вид в
            // зеркале, трансформом слоя.
            for connection in [output.connection(with: .video), previewLayer.connection].compactMap({ $0 })
            where connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()

            self.device = device
            self.format = chosen
            configured = true
            completion(device.localizedName)
        }
    }

    private enum CameraError: Error { case cannotAdd }

    /// Встроенная камера первой, затем внешняя; спящие (крышка закрыта)
    /// пропускаются. Continuity Camera (iPhone) не используем: для неё нужен
    /// отдельный ключ Info.plist, и она «уплывает» вместе с телефоном.
    private static func pickDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                       mediaType: .video, position: .unspecified).devices
        let candidates = devices.map {
            LipCameraCandidate(isBuiltIn: $0.deviceType == .builtInWideAngleCamera, isSuspended: $0.isSuspended)
        }
        return LipCameraChooser.pick(candidates).map { devices[$0] }
    }

    /// Ровно 1280×720 с 30 к/с, иначе наименьший формат от 720p с ≥ 25 к/с.
    private static func pickFormat(_ device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, frameDuration: CMTime)? {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        func supports(_ f: AVCaptureDevice.Format, _ fps: Double) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        let candidates = device.formats.filter {
            let d = dims($0)
            return d.width >= 1280 && d.height >= 720 && (supports($0, 30) || supports($0, 25))
        }
        let sorted = candidates.sorted {
            let a = dims($0), b = dims($1)
            let exactA = a.width == 1280 && a.height == 720, exactB = b.width == 1280 && b.height == 720
            if exactA != exactB { return exactA }
            let thirtyA = supports($0, 30), thirtyB = supports($1, 30)
            if thirtyA != thirtyB { return thirtyA }
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }
        guard let best = sorted.first else { return nil }
        let fps: Int32 = supports(best, 30) ? 30 : 25
        return (best, CMTime(value: 1, timescale: fps))
    }

    // MARK: - Дубль

    func begin(_ recorder: LipTakeRecorder) {
        videoQueue.async { [self] in
            current = recorder
            recorders[recorder.take.id] = recorder
            frameStats = FrameStats()
        }
        sessionQueue.async { [self] in
            // Имя камеры, эффекты и номинал кадра — ДО `startRunning`: он
            // блокирует на сотни мс, и короткий дубль успел бы дописаться без них.
            let name = device?.localizedName ?? ""
            let effects = currentEffects()
            let frameDuration = format.map { CMTimeGetSeconds($0.frameDuration) }
            videoQueue.async {
                recorder.camera = name
                recorder.effects = effects
            }
            if let frameDuration {
                visionQueue.async { [self] in cadence.frameDuration = frameDuration }
            }
            wantRunning = true
            reconcile()
        }
    }

    func end() {
        videoQueue.async { [self] in
            guard let recorder = current else { return }
            current = nil
            let frames = frameStats
            // Сначала дренируем Vision: результаты по последним кадрам должны
            // попасть в журнал до финализации — их записи уже стоят в
            // `videoQueue` раньше блока финализации.
            visionQueue.async { [self] in
                // Сводка — здесь, на очереди Vision: её состояние, и
                // `videoQueue` в это время уже принимает кадры следующего дубля.
                let vision = (visionStats.take == recorder.take.id ? visionStats : VisionStats()).summary()
                videoQueue.async { [self] in
                    recorder.finish { [self] ok in
                        recorders[recorder.take.id] = nil
                        let span = (recorder.lastFrameHost ?? 0) - (recorder.firstFrameHost ?? 0)
                        NSLog("DOKA: губы — дубль %@: кадров %d, %@; Vision %d из %d (p50 %.1f мс, p95 %.1f мс, ошибок %d), журнал лица %d (%.1f/с); сброшено камерой: опоздали %d, нет буферов %d, разрыв %d, без причины %d, прочие %d",
                              recorder.take.id.uuidString, recorder.frameCount, ok ? "записан" : "сбой",
                              vision.count, frames.seen, vision.p50, vision.p95, vision.failures,
                              recorder.faceCount, span > 0 ? Double(recorder.faceCount) / span : 0,
                              frames.droppedLate, frames.droppedOutOfBuffers, frames.droppedDiscontinuity,
                              frames.droppedNoReason, frames.droppedOther)
                        // Сбойный дубль тоже идёт дальше: журнал записан, и
                        // причину посчитает обработчик.
                        if !recorder.isDiscarded { onTakeCaptured?(recorder.take) }
                    }
                }
            }
        }
        sessionQueue.async { [self] in
            wantRunning = false
            reconcile()
        }
    }

    func discard(_ take: LipTake) {
        videoQueue.async { [self] in
            if let recorder = recorders[take.id] {
                // Ещё не дописан: «записан» уже не придёт, и забывать нечего.
                if current === recorder { current = nil }
                recorders[take.id] = nil
                recorder.discard()
            } else {
                // Дописан и о нём сообщили — теперь сообщить, что выброшен.
                try? FileManager.default.removeItem(at: take.folder)
                onTakeDiscarded?(take)
            }
        }
    }

    func shutdown() {
        sessionQueue.sync {
            wantRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Привести сессию к желаемому состоянию. Каждый блок sessionQueue сверяет
    /// факт с желаемым, поэтому устаревший старт после стопа (и наоборот) не
    /// выполнится. Между дублями камера действительно гаснет — так задумано:
    /// индикатор горит только во время записи.
    private func reconcile() {
        if wantRunning, !session.isRunning, configured {
            guard let device, let format else { return }
            // Формат и частота держатся, только пока устройство залочено во
            // время `startRunning`: иначе сессия выберет формат сама и в
            // темноте опустит частоту до 15 к/с.
            do {
                try device.lockForConfiguration()
                device.activeFormat = format.format
                device.activeVideoMinFrameDuration = format.frameDuration
                device.activeVideoMaxFrameDuration = format.frameDuration
                session.startRunning()
                device.unlockForConfiguration()
            } catch {
                NSLog("DOKA: губы — камеру не залочить: %@", error.localizedDescription)
                session.startRunning()
            }
        } else if !wantRunning, session.isRunning {
            session.stopRunning()
        }
    }

    private func handleCameraLoss() {
        videoQueue.async { [self] in current?.markFailed() }
        sessionQueue.async { [self] in
            configured = false
            device = nil
        }
    }

    /// Эффекты без запущенной сессии: глобальный тумблер пользователя ×
    /// поддержка выбранным форматом (так их и включает система).
    private func currentEffects() -> LipCaptureLog.Effects {
        guard let f = format?.format else {
            return LipCaptureLog.Effects(centerStage: false, portrait: false, studioLight: false,
                                         backgroundReplacement: false, reactions: false)
        }
        return LipCaptureLog.Effects(
            centerStage: AVCaptureDevice.isCenterStageEnabled && f.isCenterStageSupported,
            portrait: AVCaptureDevice.isPortraitEffectEnabled && f.isPortraitEffectSupported,
            studioLight: AVCaptureDevice.isStudioLightEnabled && f.isStudioLightSupported,
            backgroundReplacement: AVCaptureDevice.isBackgroundReplacementEnabled && f.isBackgroundReplacementSupported,
            reactions: AVCaptureDevice.reactionEffectsEnabled && f.reactionEffectsSupported)
    }

    // MARK: - Кадры (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard current != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostClock = CMClockGetHostTimeClock()
        let host = CMTimeGetSeconds(CMSyncConvertTime(pts, from: session.synchronizationClock ?? hostClock,
                                                      to: hostClock))
        handleFrame(sampleBuffer, host: host)
    }

    /// Кадр на хост-шкале: в сырьё дубля и, если Vision свободен, — в поиск
    /// лица. Только на `videoQueue`; тесты подают кадры сюда без камеры.
    func handleFrame(_ sampleBuffer: CMSampleBuffer, host: Double) {
        dispatchPrecondition(condition: .onQueue(videoQueue))
        guard let recorder = current, host >= recorder.acceptFromHost else { return }
        recorder.append(sampleBuffer, host: host)
        frameStats.seen += 1

        // На `videoQueue` — только проба замка и `async`: кадры камеры не
        // ждут ни Vision, ни журнала.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              visionGate.withLock({ busy in
                  guard !busy else { return false }
                  busy = true
                  return true
              }) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let take = recorder.take.id
        visionQueue.async { [self] in
            defer { visionGate.withLock { $0 = false } }
            let started = CACurrentMediaTime()
            let sample: LipFaceSample
            let failed: Bool
            do {
                sample = try detector.detect(in: pixelBuffer)
                failed = false
            } catch {
                // Для журнала это кадр без лица — как и было, когда детектор
                // глотал ошибку сам.
                sample = .none
                failed = true
            }
            visionStats.add(CACurrentMediaTime() - started, failed: failed, take: take)
            // Журнал и зеркало — на прежнем ритме: запись в журнал встаёт в
            // `videoQueue` раньше, чем блок финализации из `end()`.
            guard cadence.admit(host: host, take: take) else { return }
            videoQueue.async { [self] in
                recorder.addFace(sample, host: host)
                onFace?(sample, size)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let recorder = current else { return }
        recorder.noteDropped()
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String
        frameStats.noteDropped(reason: reason)
    }
}

/// Сводка кадров дубля для лога (в `capture.json` не идёт): сколько кадров
/// пришло и почему камера сбрасывала остальные. «Опоздал» — не успела
/// `videoQueue`, «нет буферов» — пул камеры держат Vision или кодер,
/// «разрыв» — `Discontinuity`.
///
/// «Без причины» — отдельный счётчик: причину сброса SDK обещает только на
/// iOS (`AVCaptureVideoDataOutput.h`), и на Mac камера может её не
/// прикладывать. Свались такие сбросы в «прочие» — «нет буферов 0» в логе
/// выглядело бы доказательством, хотя причину просто не узнать.
private struct FrameStats {
    var seen = 0
    var droppedLate = 0
    var droppedOutOfBuffers = 0
    var droppedDiscontinuity = 0
    var droppedNoReason = 0
    /// Причина есть, но незнакомая.
    var droppedOther = 0

    mutating func noteDropped(reason: String?) {
        guard let reason else {
            droppedNoReason += 1
            return
        }
        if reason == kCMSampleBufferDroppedFrameReason_FrameWasLate as String {
            droppedLate += 1
        } else if reason == kCMSampleBufferDroppedFrameReason_OutOfBuffers as String {
            droppedOutOfBuffers += 1
        } else if reason == kCMSampleBufferDroppedFrameReason_Discontinuity as String {
            droppedDiscontinuity += 1
        } else {
            droppedOther += 1
        }
    }
}

/// Время Vision на кадр за дубль — для лога. Живёт на `visionQueue` и
/// начинается заново с первым кадром следующего дубля.
private struct VisionStats {
    var take: UUID?
    var seconds: [Double] = []
    var failures = 0

    mutating func add(_ duration: Double, failed: Bool, take: UUID) {
        if take != self.take { self = VisionStats(take: take) }
        seconds.append(duration)
        if failed { failures += 1 }
    }

    /// Итог для лога: одна сортировка на оба перцентиля, мс; 0 — кадров не было.
    func summary() -> (count: Int, p50: Double, p95: Double, failures: Int) {
        let sorted = seconds.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[Int((p * Double(sorted.count - 1)).rounded())] * 1000
        }
        return (sorted.count, percentile(0.5), percentile(0.95), failures)
    }
}
