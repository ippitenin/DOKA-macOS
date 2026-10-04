import AVFoundation
import Combine
import QuartzCore

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

    /// Перед дублем нужно столько свободного места: сырьё длинной диктовки —
    /// десятки мегабайт, и забивать диск до отказа ради пар нельзя.
    private static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let settings = SettingsStore.shared
        // Камера дописала сырьё дубля — событие для хранилища пар.
        engine.onTakeCaptured = { take in
            Task { @MainActor in LipDataStore.shared.captureFinished(take) }
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
        guard Self.hasFreeSpace() else {
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
    }

    func discard(_ take: LipTake) {
        engine.discard(take)
        LipDataStore.shared.forget(take)
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

    private static func hasFreeSpace() -> Bool {
        let url = AppDataFolder.defaultURL
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > minFreeBytes
    }
}

/// Сессия камеры и маршрутизация кадров. Три последовательные очереди:
/// `sessionQueue` — настройка, старт и стоп (`startRunning` блокирует на
/// сотни мс, главному потоку этого нельзя); `videoQueue` — кадры и текущий
/// дубль; `visionQueue` — поиск лица.
final class LipCameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "com.pitenin.doka.lips.video", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "com.pitenin.doka.lips.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.pitenin.doka.lips.vision", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let tracker = LipFaceTracker()

    /// Результат Vision для зеркала: образец лица и размер кадра. Зовётся на
    /// `videoQueue`, не чаще ~15 раз в секунду.
    var onFace: (@Sendable (LipFaceSample, CGSize) -> Void)?
    /// Сырьё дубля дописано (не выброшенного). Зовётся на `videoQueue`.
    var onTakeCaptured: (@Sendable (LipTake) -> Void)?

    // Состояние sessionQueue.
    private var device: AVCaptureDevice?
    private var configured = false
    private var wantRunning = false
    private var format: (format: AVCaptureDevice.Format, frameDuration: CMTime)?

    // Состояние videoQueue.
    private var current: LipTakeRecorder?
    private var recorders: [UUID: LipTakeRecorder] = [:]
    private var frameIndex = 0
    private var visionBusy = false

    private var observers: [NSObjectProtocol] = []

    override init() {
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
            frameIndex = 0
        }
        sessionQueue.async { [self] in
            wantRunning = true
            reconcile()
            let name = device?.localizedName ?? ""
            let effects = currentEffects()
            videoQueue.async {
                recorder.camera = name
                recorder.effects = effects
            }
        }
    }

    func end() {
        videoQueue.async { [self] in
            guard let recorder = current else { return }
            current = nil
            // Сначала дренируем Vision: результаты по последним кадрам должны
            // попасть в журнал до финализации.
            visionQueue.async { [self] in
                videoQueue.async { [self] in
                    recorder.finish { [self] ok in
                        recorders[recorder.take.id] = nil
                        NSLog("DOKA: губы — дубль %@: кадров %d, %@", recorder.take.id.uuidString,
                              recorder.frameCount, ok ? "записан" : "сбой")
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
                if current === recorder { current = nil }
                recorders[take.id] = nil
                recorder.discard()
            } else {
                try? FileManager.default.removeItem(at: take.folder)
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

    private func currentEffects() -> LipCaptureLog.Effects {
        LipCaptureLog.Effects(
            centerStage: device?.isCenterStageActive ?? false,
            portrait: device?.isPortraitEffectActive ?? false,
            studioLight: device?.isStudioLightActive ?? false,
            backgroundReplacement: device?.isBackgroundReplacementActive ?? false,
            reactions: AVCaptureDevice.reactionEffectsEnabled && (device?.canPerformReactionEffects ?? false))
    }

    // MARK: - Кадры (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let recorder = current else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostClock = CMClockGetHostTimeClock()
        let host = CMTimeGetSeconds(CMSyncConvertTime(pts, from: session.synchronizationClock ?? hostClock,
                                                      to: hostClock))
        guard host >= recorder.acceptFromHost else { return }
        recorder.append(sampleBuffer, host: host)

        // Лицо — на каждом втором кадре (15 Гц) и только если Vision свободен.
        frameIndex += 1
        guard frameIndex.isMultiple(of: 2), !visionBusy,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        visionBusy = true
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        visionQueue.async { [self] in
            let sample = tracker.detect(in: pixelBuffer)
            videoQueue.async { [self] in
                visionBusy = false
                recorder.addFace(sample, host: host)
                onFace?(sample, size)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        current?.noteDropped()
    }
}
