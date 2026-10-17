import AVFoundation
import VideoToolbox

/// Можно ли «Губам» кодировать видео аппаратно (AVE). По умолчанию — НЕТ:
/// разрешение ставит только `main.swift`, а тесты `main.swift` не исполняют
/// и поэтому всегда кодируют программно. Тесты с аппаратным кодировщиком
/// дважды роняли ядро (`dart-ave0`, 17.10.2026, `Tests/DOKATests/CLAUDE.md`).
///
/// Любая видеодорожка `AVAssetWriterInput` — в приложении и в тестах —
/// берёт настройки ТОЛЬКО через `outputSettings`; сторож —
/// `LipVideoEncodingTests`.
enum LipVideoEncoding {
    static var hardwareAllowed = false

    /// `AVVideoEncoderSpecificationKey` программного кодировщика.
    static let softwareSpecification: [String: Any] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false
    ]

    /// Настройки видеодорожки; без разрешения — с программным кодировщиком.
    static func outputSettings(_ settings: [String: Any]) -> [String: Any] {
        guard !hardwareAllowed else { return settings }
        var settings = settings
        settings[AVVideoEncoderSpecificationKey] = softwareSpecification
        return settings
    }
}
