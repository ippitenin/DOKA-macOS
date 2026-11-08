import AVFoundation
import XCTest
@testable import DOKA

/// Настоящий конвертер и WAV, но без AVAudioEngine и доступа к микрофону.
final class AudioRecorderPauseTests: XCTestCase {
    func testPausedAudioAndSpeechCountersAreExcludedAndResumeAppends() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: target))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doka-pause-test-\(UUID()).wav")
        let writer = try WavWriter(url: url)
        defer { writer.cancelAndDelete() }
        let session = AudioRecorder.Session(converter: converter, writer: writer,
                                            targetFormat: target, quiet: false)
        let recorder = AudioRecorder()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        func feed(_ amplitude: Float, at time: Double) {
            for i in 0..<4800 { channel[i] = amplitude * sin(Float(i) * 0.06) }
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time))
            recorder.process(buffer: buffer, when: when, in: session)
        }
        for i in 0..<10 { feed(0.1, at: 100 + Double(i) / 10) }
        let elapsed = recorder.pause(session)
        let speech = session.speechTime
        let quietSpeech = session.quietSpeechTime
        XCTAssertEqual(elapsed, 1, accuracy: 0.003)
        XCTAssertNil(session.timing, "После паузы непрерывная шкала камеры неприменима")
        for i in 0..<100 { feed(0.9, at: 101 + Double(i) / 10) }
        XCTAssertEqual(writer.duration, elapsed)
        XCTAssertEqual(session.speechTime, speech)
        XCTAssertEqual(session.quietSpeechTime, quietSpeech)
        XCTAssertEqual(session.elapsed, 1, accuracy: 1e-9)
        XCTAssertEqual(recorder.pause(session), elapsed, "Повторная пауза не дожимает конвертер снова")
        session.paused = false
        for i in 0..<10 { feed(0.2, at: 111 + Double(i) / 10) }
        let total = recorder.pause(session)
        XCTAssertEqual(total, 2, accuracy: 0.003)
        XCTAssertEqual(session.speechTime, speech + 1, accuracy: 1e-9)
        try writer.finalize()
        let data = try Data(contentsOf: url)
        // Оба записанных фрагмента тихие; громкая речь паузы в WAV не попала.
        let maximum = data.dropFirst(44).withUnsafeBytes { bytes -> Int in
            var result = 0
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: Int16.self))
                result = max(result, abs(Int(sample)))
            }
            return result
        }
        XCTAssertGreaterThan(maximum, 5000)
        XCTAssertLessThan(maximum, 8000)
    }
}
