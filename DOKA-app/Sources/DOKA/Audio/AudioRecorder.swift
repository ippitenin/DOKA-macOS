import AVFoundation
import Foundation

/// Запись с микрофона: AVAudioEngine tap → AVAudioConverter → 16 кГц mono Int16 WAV.
///
/// Tap-колбэк приходит на внутреннем потоке AVAudioEngine, а start/stop/cancel —
/// с главного. Всё состояние сессии (конвертер, writer, уровень) живёт в Session
/// и доступно ТОЛЬКО на последовательной очереди `queue` — это устраняет гонку
/// между дозаписью хвостовых буферов и финализацией файла.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInputDevice
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return L("error.noInputDevice")
            case .engineStartFailed: return L("error.recordingStartFailed")
            }
        }
    }

    /// Колбэки вызываются на главном потоке.
    var onLevel: ((Float) -> Void)?
    var onConfigurationChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.pitenin.doka.audio")
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    /// Порог логарифмического уровня (0…1), выше которого буфер считается «речью».
    /// Тишина/фоновый шум (~−50…−40 дБ) даёт уровень ниже, реальный голос — выше.
    /// Нужен для оценки активного времени речи без пауз (статистика дашборда).
    ///
    /// ВАЖНО: порог живёт на СТАРОЙ dB-кривой (`speechLevel`) и не должен ехать
    /// вслед за кривой для UI — иначе поедут «Скорость речи», сэкономленное время
    /// и множитель на дашборде, которые считаются от накопленного `speechTime`.
    /// Тихий режим (шёпот) считает речь отдельным счётчиком — см. `SpeechMeter`.
    static let speechLevelThreshold: Float = 0.2

    /// Кривая уровня для панелей записи. Логарифмическая шкала (dB) сжимает
    /// обычную речь в узкий диапазон и выглядит вяло, поэтому уровень строится
    /// по линейным RMS и пику с узкими рабочими окнами: чуть выше шума — уже
    /// заметное движение, гамма поднимает тихую речь.
    private enum Level {
        static let rmsFloor: Float = 0.009
        static let rmsRange: Float = 0.018
        static let peakFloor: Float = 0.024
        static let peakRange: Float = 0.07
        static let peakWeight: Float = 0.75
        static let gamma: Float = 0.72
        /// Подъём быстрый, спад медленный: голос должен «выстреливать» сразу,
        /// а затухать плавно, иначе панель дёргается на паузах между словами.
        static let attack: Float = 0.5
        static let release: Float = 0.18

        static func normalize(rms: Float, peak: Float) -> Float {
            let rmsLevel = max(0, min(1, (rms - rmsFloor) / rmsRange))
            let peakLevel = max(0, min(1, (peak - peakFloor) / peakRange))
            return pow(max(rmsLevel, peakLevel * peakWeight), gamma)
        }
    }

    /// Состояние одной сессии записи. Доступ только на `queue`.
    private final class Session {
        let converter: AVAudioConverter
        let writer: WavWriter
        let targetFormat: AVAudioFormat
        /// Тихий режим (шёпот): уровень для панелей поднимается на
        /// `SpeechMeter.quietDisplayGain`, иначе на шёпоте волна стоит.
        let quiet: Bool
        var smoothedLevel: Float = 0
        /// Накопленное время, когда реально звучал голос (сек), без тишины и пауз.
        var speechTime: TimeInterval = 0
        /// То же по порогу тихого режима (`SpeechMeter.quietThresholdDb`) — для
        /// гейта шёпотных диктовок. Копится всегда, гейт выбирает по режиму.
        var quietSpeechTime: TimeInterval = 0
        var finished = false
        /// Метки времени для сшивки с камерой (эксперимент «Губы»).
        /// Задержка входа; читается после старта движка (до него она бывает 0).
        var inputLatency: TimeInterval = 0
        /// Секунды звука, полученные до текущего буфера (по входной частоте).
        var elapsed: TimeInterval = 0
        var onset = SpeechOnsetTracker()
        var drift = HostClockDriftTracker()

        init(converter: AVAudioConverter, writer: WavWriter, targetFormat: AVAudioFormat, quiet: Bool) {
            self.converter = converter
            self.writer = writer
            self.targetFormat = targetFormat
            self.quiet = quiet
        }

        var timing: RecordingTiming? {
            guard let hostStart = drift.hostStart else { return nil }
            return RecordingTiming(hostStart: hostStart, inputLatency: inputLatency,
                                   speechOnset: onset.onset, maxClockDrift: drift.maxDrift)
        }
    }

    /// Итог записи.
    struct Recording {
        let url: URL
        let duration: TimeInterval
        /// Время активной речи (сек) без тишины и пауз — по обычному порогу.
        let speechDuration: TimeInterval
        /// То же по порогу тихого режима.
        let quietSpeechDuration: TimeInterval
        /// Запись шла в тихом режиме.
        let quiet: Bool
        /// Хост-время старта и начало речи — для сшивки с видео губ; nil —
        /// движок не дал хост-времени.
        let timing: RecordingTiming?
    }

    private var session: Session?   // мутируется только внутри queue.sync

    var isRecording: Bool { engine != nil }

    /// Имя текущего системного устройства ввода по умолчанию — для метаданных истории.
    /// Best-effort: может быть nil (нет устройства/прав). Читать на главном потоке.
    var currentInputDeviceName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Стартует запись во временный WAV-файл, возвращает его URL.
    /// `quiet` — тихий режим (шёпот): влияет только на уровень для панелей,
    /// оба счётчика речи копятся всегда.
    func start(quiet: Bool = false) throws -> URL {
        teardownEngine()
        discardSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.noInputDevice
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url)
        let newSession = Session(converter: converter, writer: writer, targetFormat: targetFormat,
                                 quiet: quiet)
        queue.sync { session = newSession }

        let queue = self.queue
        // 1024 кадра — ~21 мс при 48 кГц: панели получают уровень ~47 раз в секунду.
        // На 4096 (~85 мс) реакция на голос заметно запаздывала.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, when in
            // Сессия захвачена по значению: «хвостовые» колбэки старой сессии
            // после finished=true просто отбрасываются.
            queue.async { self?.process(buffer: buffer, when: when, in: newSession) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            discardSession()
            throw RecorderError.engineStartFailed(error)
        }
        self.engine = engine
        let latency = input.presentationLatency
        queue.sync { newSession.inputLatency = latency }

        // Смена/пропажа аудиоустройства (подключили AirPods и т.п.).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        return url
    }

    /// Останавливает запись, дожимает хвост конвертера и финализирует WAV.
    func stop() -> Recording? {
        teardownEngine()
        var result: Recording?
        queue.sync {
            guard let s = session, !s.finished else {
                session = nil
                return
            }
            s.finished = true
            drain(s)
            let duration = s.writer.duration
            do {
                try s.writer.finalize()
                result = Recording(url: s.writer.url, duration: duration,
                                   speechDuration: s.speechTime,
                                   quietSpeechDuration: s.quietSpeechTime, quiet: s.quiet,
                                   timing: s.timing)
            } catch {
                NSLog("DOKA: ошибка финализации WAV: \(error.localizedDescription)")
                s.writer.cancelAndDelete()
            }
            session = nil
        }
        return result
    }

    /// Отмена: остановить и удалить файл.
    func cancelAndDelete() {
        teardownEngine()
        discardSession()
    }

    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func discardSession() {
        queue.sync {
            session?.finished = true
            session?.writer.cancelAndDelete()
            session = nil
        }
    }

    // Выполняется на queue.
    private func process(buffer: AVAudioPCMBuffer, when: AVAudioTime, in session: Session) {
        guard !session.finished else { return }

        // Хост-время буфера — шкала, по которой видео губ сшивается с WAV.
        let bufferStart = session.elapsed
        if when.isHostTimeValid {
            session.drift.feed(host: AVAudioTime.seconds(forHostTime: when.hostTime), elapsed: bufferStart)
        }
        session.elapsed += Double(buffer.frameLength) / buffer.format.sampleRate

        // Уровень: RMS и пик по первому каналу исходного float-буфера.
        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            if frames > 0 {
                var sum: Float = 0
                var peak: Float = 0
                for i in 0..<frames {
                    let sample = channel[i]
                    sum += sample * sample
                    peak = max(peak, abs(sample))
                }
                let rms = sqrt(sum / Float(frames))

                // Статистика речи считается по прежней dB-кривой: её порог
                // калиброван под неё, а lifetime-агрегаты дашборда — под порог.
                let db = 20 * log10(max(rms, 1e-7))
                let speechLevel = max(0, min(1, (db + 50) / 50))
                let seconds = Double(frames) / buffer.format.sampleRate
                let isSpeech = speechLevel >= Self.speechLevelThreshold
                let isQuietSpeech = SpeechMeter.isQuietSpeech(db: db)
                if isSpeech {
                    session.speechTime += seconds
                }
                if isQuietSpeech {
                    session.quietSpeechTime += seconds
                }
                // Начало речи — по порогу того режима, в котором идёт запись.
                session.onset.feed(isSpeech: session.quiet ? isQuietSpeech : isSpeech, at: bufferStart)

                // Уровень для панелей — своя кривая с быстрым подъёмом.
                let gain: Float = session.quiet ? SpeechMeter.quietDisplayGain : 1
                let target = Level.normalize(rms: rms * gain, peak: min(1, peak * gain))
                let response = target > session.smoothedLevel ? Level.attack : Level.release
                session.smoothedLevel += (target - session.smoothedLevel) * response
                let level = session.smoothedLevel
                DispatchQueue.main.async { [weak self] in
                    self?.onLevel?(level)
                }
            }
        }

        // Ресемплинг в 16 кГц mono Int16.
        let ratio = session.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: session.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        let status = session.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, convError == nil else { return }
        append(outBuffer, to: session)
    }

    // Выполняется на queue: дожимает остаток сэмплов из конвертера.
    private func drain(_ session: Session) {
        for _ in 0..<8 {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: session.targetFormat, frameCapacity: 4096) else { return }
            var convError: NSError?
            let status = session.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            append(outBuffer, to: session)
            if status != .haveData || outBuffer.frameLength == 0 { return }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to session: Session) {
        guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        session.writer.append(Data(bytes: samples, count: byteCount))
    }
}
