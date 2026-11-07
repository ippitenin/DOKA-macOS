import XCTest
@testable import DOKA

/// Слот локальной модели один на приложение. Ошибка политики в одну сторону —
/// диктовка «висит» в очереди за часовым файлом, в другую — файл теряет модель
/// посреди работы.
final class SpeechSlotPolicyTests: XCTestCase {

    private func lease(_ holders: SpeechSlotHolder...) -> SpeechSlotLease {
        var lease = SpeechSlotLease()
        holders.forEach { lease.begin($0) }
        return lease
    }

    // MARK: - Аренда

    func testEmptyLeaseIsFree() {
        XCTAssertFalse(SpeechSlotLease().isHeld)
    }

    func testLeaseCountsNestedUses() {
        var lease = lease(.fileSpeech, .fileSpeech)
        lease.end(.fileSpeech)
        XCTAssertTrue(lease.isHeld(by: .fileSpeech))
        lease.end(.fileSpeech)
        XCTAssertFalse(lease.isHeld)
    }

    /// Лишний `end` не должен «съесть» следующую аренду.
    func testExtraEndDoesNotGoNegative() {
        var lease = SpeechSlotLease()
        lease.end(.dictation)
        lease.begin(.dictation)
        XCTAssertTrue(lease.isHeld(by: .dictation))
    }

    // MARK: - Старт диктовки

    func testLocalDictationIsRefusedWhileFileHoldsSpeech() {
        XCTAssertEqual(SpeechSlotPolicy.dictationStart(isLocal: true, lease: lease(.fileSpeech)), .busyFile)
    }

    func testNetworkDictationIgnoresLocalFile() {
        XCTAssertEqual(SpeechSlotPolicy.dictationStart(isLocal: false, lease: lease(.fileSpeech)), .ok)
    }

    /// Диаризация сетевого файла речевую модель не держит — диктовке не мешает.
    func testLocalDictationIsAllowedDuringNetworkFileDiarization() {
        XCTAssertEqual(SpeechSlotPolicy.dictationStart(isLocal: true, lease: lease(.fileDiarization)), .ok)
    }

    func testLocalDictationIsAllowedWhenSlotIsFree() {
        XCTAssertEqual(SpeechSlotPolicy.dictationStart(isLocal: true, lease: SpeechSlotLease()), .ok)
    }

    // MARK: - Старт файла

    func testLocalFileIsRefusedDuringLocalDictation() {
        XCTAssertEqual(SpeechSlotPolicy.fileStart(isLocalRoute: true, lease: lease(.dictation)), .busyDictation)
    }

    func testNetworkFileIsAllowedDuringLocalDictation() {
        XCTAssertEqual(SpeechSlotPolicy.fileStart(isLocalRoute: false, lease: lease(.dictation)), .ok)
    }

    func testLocalFileIsAllowedWhenSlotIsFree() {
        XCTAssertEqual(SpeechSlotPolicy.fileStart(isLocalRoute: true, lease: SpeechSlotLease()), .ok)
    }

    // MARK: - Загрузка движка

    func testSameModelIsReused() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: .parakeet, loading: nil,
                                             lease: lease(.fileSpeech)), .reuse)
    }

    func testSameModelLoadingIsAwaited() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .whisper, loaded: nil, loading: .whisper,
                                             lease: SpeechSlotLease()), .awaitLoading)
    }

    /// Без аренды — прежнее поведение: смена модели выгружает всё.
    func testWithoutLeaseOtherModelIsEvicted() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: .whisper, loading: nil,
                                             lease: SpeechSlotLease()),
                       .load(unloadSpeech: true, unloadDiarizer: true))
    }

    /// Главный случай бага: файл на Whisper, диктовка просит Parakeet.
    func testOtherModelIsRefusedWhileFileHoldsSpeech() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: .whisper, loading: nil,
                                             lease: lease(.fileSpeech)), .refuse)
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: nil, loading: .whisper,
                                             lease: lease(.fileSpeech)), .refuse)
    }

    /// Сетевой файл диаризует: речевая модель грузится рядом, диаризатор цел.
    func testDuringFileDiarizationSpeechLoadsBesideDiarizer() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: nil, loading: nil,
                                             lease: lease(.fileDiarization)),
                       .load(unloadSpeech: false, unloadDiarizer: false))
        // Чужая речевая модель от прошлой диктовки файлу не нужна — её можно сменить.
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: .whisper, loading: nil,
                                             lease: lease(.fileDiarization)),
                       .load(unloadSpeech: true, unloadDiarizer: false))
    }

    /// Аренда самой диктовки ей же не мешает менять модель.
    func testDictationLeaseDoesNotBlockItsOwnLoad() {
        XCTAssertEqual(SpeechSlotPolicy.load(requested: .parakeet, loaded: .whisper, loading: nil,
                                             lease: lease(.dictation)),
                       .load(unloadSpeech: true, unloadDiarizer: true))
    }

    // MARK: - Выгрузка

    func testIdleUnloadWaitsForLease() {
        XCTAssertTrue(SpeechSlotPolicy.idleUnloadAllowed(lease: SpeechSlotLease()))
        for holder in SpeechSlotHolder.allCases {
            XCTAssertFalse(SpeechSlotPolicy.idleUnloadAllowed(lease: lease(holder)), "\(holder)")
        }
    }

    func testServiceSwitchUnloadIsDeferredUnderLease() {
        XCTAssertEqual(SpeechSlotPolicy.serviceSwitchUnload(lease: SpeechSlotLease()), .now)
        for holder in SpeechSlotHolder.allCases {
            XCTAssertEqual(SpeechSlotPolicy.serviceSwitchUnload(lease: lease(holder)), .deferred, "\(holder)")
        }
    }
}
