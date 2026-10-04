import Foundation

/// Отметка трекера лиц на шкале WAV.
struct LipFaceMark: Equatable {
    var t: Double
    var hasFace: Bool
}

/// Всё, что известно о дубле к моменту решения.
struct LipTakeFacts {
    var text: String
    var cameraFailed: Bool
    var measuredFps: Double
    /// Аудиодвижок дал хост-время старта.
    var timingKnown: Bool
    var maxClockDrift: Double
    var duration: Double
    var speechOnset: Double?
    var validFrom: Double
    var validTo: Double
    var faceSamples: [LipFaceMark]
    var faceInOutputPx: Double
}

/// Почему дубль не стал парой. Порядок кейсов — порядок проверок.
enum LipRejectReason: String, Codable, CaseIterable {
    case emptyText
    case cameraFailed
    case syncLost
    case lowFps
    /// Полезного видео меньше полутора секунд — фраза короче, чем нужно модели.
    case tooShort
    case noFace
    case faceTooSmall
    case lateCamera
    case encodeFailed

    var title: String {
        switch self {
        case .emptyText: return L("lips.reject.emptyText")
        case .cameraFailed: return L("lips.reject.cameraFailed")
        case .syncLost: return L("lips.reject.syncLost")
        case .lowFps: return L("lips.reject.lowFps")
        case .tooShort: return L("lips.reject.tooShort")
        case .noFace: return L("lips.reject.noFace")
        case .faceTooSmall: return L("lips.reject.faceTooSmall")
        case .lateCamera: return L("lips.reject.lateCamera")
        case .encodeFailed: return L("lips.reject.encodeFailed")
        }
    }
}

/// Решение по дублю: плохая пара хуже отсутствующей (модель учится на шуме),
/// но и лишнего не выбрасываем — холодная камера пропускает начало почти
/// каждого дубля, это помечается окном `validFrom…validTo`, а не отбраковкой.
enum LipTakeVerdict: Equatable {
    /// `headMissing` — камера проснулась после начала речи.
    case keep(headMissing: Bool)
    case reject(LipRejectReason)

    static let maxClockDrift = 0.04
    static let minFps = 24.0
    static let minFaceCoverage = 0.5
    static let minUsefulSeconds = 1.5
    /// Лицо в выходном кадре 512 px мельче этого — S3FD WISLIP на уменьшенном
    /// вчетверо кадре его не найдёт.
    static let minFacePx = 110.0
    static let minSpeechCoverage = 0.5
    /// Пропуск лица дольше этого — «дыра» в `faceGaps`.
    static let minGap = 0.2
    /// Камера опоздала к речи больше чем на столько — счётчик «начало без видео».
    static let headTolerance = 0.1

    static func decide(_ f: LipTakeFacts) -> LipTakeVerdict {
        if f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .reject(.emptyText) }
        if f.cameraFailed { return .reject(.cameraFailed) }
        if !f.timingKnown || f.maxClockDrift > maxClockDrift { return .reject(.syncLost) }
        if f.measuredFps < minFps { return .reject(.lowFps) }

        // Сначала длина окна, потом лицо: короткая фраза при хорошем свете — это
        // «слишком коротко», а не «лица не видно».
        let window = max(0, f.validTo - f.validFrom)
        if window < minUsefulSeconds { return .reject(.tooShort) }
        let coverage = faceCoverage(f.faceSamples, validFrom: f.validFrom, validTo: f.validTo)
        if coverage < minFaceCoverage || window * coverage < minUsefulSeconds { return .reject(.noFace) }
        if f.faceInOutputPx < minFacePx { return .reject(.faceTooSmall) }

        let speechStart = f.speechOnset ?? 0
        let speech = max(0, f.duration - speechStart)
        if speech > 0 {
            let covered = max(0, min(f.validTo, f.duration) - max(f.validFrom, speechStart))
            if covered / speech < minSpeechCoverage { return .reject(.lateCamera) }
        }
        return .keep(headMissing: f.validFrom > speechStart + headTolerance)
    }

    /// Доля отметок с лицом внутри полезного окна.
    static func faceCoverage(_ samples: [LipFaceMark], validFrom: Double, validTo: Double) -> Double {
        let inside = samples.filter { $0.t >= validFrom && $0.t <= validTo }
        guard !inside.isEmpty else { return 0 }
        return Double(inside.filter(\.hasFace).count) / Double(inside.count)
    }

    /// Интервалы без лица дольше `minGap` внутри полезного окна, [начало, конец].
    static func faceGaps(_ samples: [LipFaceMark], validFrom: Double, validTo: Double) -> [[Double]] {
        let inside = samples.filter { $0.t >= validFrom && $0.t <= validTo }
        var gaps: [[Double]] = []
        var start: Double?
        for mark in inside {
            if mark.hasFace {
                if let s = start, mark.t - s >= minGap { gaps.append([s, mark.t]) }
                start = nil
            } else if start == nil {
                start = mark.t
            }
        }
        if let s = start, validTo - s >= minGap { gaps.append([s, validTo]) }
        return gaps
    }
}
