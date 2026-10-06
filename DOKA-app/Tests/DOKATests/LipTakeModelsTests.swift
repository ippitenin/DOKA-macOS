import XCTest
@testable import DOKA

/// `meta.json` v1 — договор с WISLIP: импортёр на Python читает эти поля.
///
/// Зачем: переименование поля или смена формата даты молча сломает обучение
/// на стороне WISLIP. Замороженная фикстура ниже обязана читаться всегда;
/// менять её можно только вместе с `schemaVersion` и импортёром WISLIP.
final class LipTakeModelsTests: XCTestCase {

    private let fixture = """
    {"schemaVersion":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"2026-10-04T12:00:00Z",
     "source":"dictation","mode":"whisper","text":"привет, это шёпот","language":"ru",
     "provider":"Nexara","model":"whisper-1","historyID":"0B3A2F00-0000-4000-8000-000000000001",
     "duration":21.8,"speechSeconds":14.2,"quietSpeechSeconds":16.0,"speechOnset":0.42,"quiet":true,
     "video":{"width":512,"height":512,"fps":30,"validFrom":0.71,"validTo":21.8,"faceCoverage":0.97,
      "faceGaps":[[3.1,3.6]],"cropRect":[402,96,560,560],"cameraFrame":[1280,720],
      "camera":"FaceTime HD Camera","measuredFps":29.97,"droppedFrames":2,"multiFaceFrames":0,
      "mirrored":false,"effects":{"centerStage":false,"portrait":false,"studioLight":false,
      "backgroundReplacement":false,"reactions":false}},
     "audio":{"sampleRate":16000,"codec":"aac","inputLatency":0.004,"maxClockDrift":0.003,
      "microphone":"MacBook Pro Microphone"},
     "appVersion":"1.0.0"}
    """

    func testFrozenFixtureDecodes() throws {
        let meta = try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: Data(fixture.utf8))
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertEqual(meta.mode, .whisper)
        XCTAssertEqual(meta.source, "dictation")
        XCTAssertEqual(meta.text, "привет, это шёпот")
        XCTAssertEqual(meta.date, Date(timeIntervalSince1970: 1_791_115_200))
        XCTAssertEqual(meta.video.validFrom, 0.71)
        XCTAssertEqual(meta.video.faceGaps, [[3.1, 3.6]])
        XCTAssertEqual(meta.video.cropRect, [402, 96, 560, 560])
        XCTAssertFalse(meta.video.mirrored)
        XCTAssertEqual(meta.audio.codec, "aac")
    }

    /// Даты — ISO 8601 строкой: Python не читает секунды от 2001 года,
    /// которые `JSONEncoder` пишет по умолчанию.
    func testEncodesDatesAsISO8601() throws {
        let meta = try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: Data(fixture.utf8))
        let json = String(decoding: try LipTakeMeta.encoder.encode(meta), as: UTF8.self)
        XCTAssertTrue(json.contains("\"date\":\"2026-10-04T12:00:00Z\""), json)
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertEqual(try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: Data(json.utf8)), meta)
    }

    /// Режим папки — по снимку тихого режима на старте записи.
    func testModeFollowsQuietFlag() {
        XCTAssertEqual(LipMode(quiet: true), .whisper)
        XCTAssertEqual(LipMode(quiet: false), .voice)
        XCTAssertEqual(LipMode.silent.rawValue, "silent")   // «Тренировка»
    }

    /// Пара окна «Тренировка» — та же схема v1: `source` "training", `mode`
    /// "silent", `historyID` нет (записи в истории нет), `speechOnset` —
    /// момент, когда на экране появилось «Говорите». Замороженная фикстура —
    /// договор с импортёром WISLIP, как и первая.
    private let trainingFixture = """
    {"schemaVersion":1,"id":"7A2B3C4D-0000-4000-8000-000000000002","date":"2026-10-06T12:00:00Z",
     "source":"training","mode":"silent","text":"Слушай, посмотри ещё раз на главную страницу.","language":"ru",
     "provider":"training","model":"work",
     "duration":4.2,"speechSeconds":0,"quietSpeechSeconds":0.1,"speechOnset":0.86,"quiet":false,
     "video":{"width":512,"height":512,"fps":30,"validFrom":0.62,"validTo":4.2,"faceCoverage":1,
      "faceGaps":[],"cropRect":[402,96,560,560],"cameraFrame":[1280,720],
      "camera":"FaceTime HD Camera","measuredFps":30,"droppedFrames":0,"multiFaceFrames":0,
      "mirrored":false,"effects":{"centerStage":false,"portrait":false,"studioLight":false,
      "backgroundReplacement":false,"reactions":false}},
     "audio":{"sampleRate":16000,"codec":"aac","inputLatency":0.004,"maxClockDrift":0.002},
     "appVersion":"1.0.0"}
    """

    func testFrozenTrainingFixtureDecodes() throws {
        let meta = try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: Data(trainingFixture.utf8))
        XCTAssertEqual(meta.source, LipSource.training.rawValue)
        XCTAssertEqual(meta.mode, .silent)
        XCTAssertNil(meta.historyID)
        XCTAssertEqual(meta.speechOnset, 0.86)
        XCTAssertEqual(meta.text, "Слушай, посмотри ещё раз на главную страницу.")
        XCTAssertEqual(meta.model, LipTrainingPhrase.Origin.work.rawValue)
        XCTAssertNil(meta.audio.microphone)
    }

    /// Подпись тренировки: показанная фраза, беззвучно, без записи истории.
    func testTrainingCaption() {
        let caption = LipCaption.training(phrase: "Купи хлеба по дороге", origin: LipTrainingPhrase.Origin.everyday.rawValue)
        XCTAssertEqual(caption.source, .training)
        XCTAssertEqual(caption.mode, .silent)
        XCTAssertNil(caption.historyID)
        XCTAssertEqual(caption.provider, LipCaption.trainingProvider)
        XCTAssertEqual(caption.model, "everyday")
        XCTAssertEqual(caption.text, "Купи хлеба по дороге")
    }

    /// `job.json` прошлой версии (без `source`/`mode`) лежит в `pending` после
    /// обновления — он обязан читаться и остаться диктовкой.
    func testJobOfPreviousVersionReadsAsDictation() throws {
        let old = """
        {"text":"привет","language":"ru","provider":"Nexara","model":"whisper-1",
         "historyID":"0B3A2F00-0000-4000-8000-000000000001","date":"2026-10-04T12:00:00Z",
         "duration":3.2,"speechSeconds":2,"quietSpeechSeconds":2.4,"quiet":true,
         "hostStart":1000,"inputLatency":0.004,"speechOnset":0.4,"maxClockDrift":0.001}
        """
        let job = try LipTakeMeta.decoder.decode(LipJob.self, from: Data(old.utf8))
        XCTAssertNil(job.source)
        XCTAssertNil(job.mode)
        XCTAssertNotNil(job.historyID)
        XCTAssertTrue(job.quiet)
    }

    /// Заказ диктовки пишется без новых ключей — файл как раньше.
    func testDictationJobOmitsTrainingKeys() throws {
        let job = LipJob(text: "привет", language: "ru", provider: "Nexara", model: "whisper-1",
                         historyID: UUID(), date: Date(), duration: 1, speechSeconds: 1,
                         quietSpeechSeconds: 1, quiet: false, microphone: nil, hostStart: 1,
                         inputLatency: 0, speechOnset: nil, maxClockDrift: 0)
        let json = String(decoding: try LipTakeMeta.encoder.encode(job), as: UTF8.self)
        XCTAssertFalse(json.contains("\"source\""), json)
        XCTAssertFalse(json.contains("\"mode\""), json)
    }

    /// `job.json` переживает перезапуск: дубль, не успевший закодироваться,
    /// доделывается после старта.
    func testJobRoundTrips() throws {
        let job = LipJob(text: "привет", language: "ru", provider: "Nexara", model: "whisper-1",
                         historyID: UUID(), date: Date(timeIntervalSince1970: 1_791_115_200),
                         duration: 3.2, speechSeconds: 2.0, quietSpeechSeconds: 2.4, quiet: false,
                         microphone: "MacBook Pro Microphone", hostStart: 1000, inputLatency: 0.004,
                         speechOnset: 0.4, maxClockDrift: 0.001)
        let data = try LipTakeMeta.encoder.encode(job)
        XCTAssertEqual(try LipTakeMeta.decoder.decode(LipJob.self, from: data), job)

        var training = job
        training.historyID = nil
        training.source = .training
        training.mode = .silent
        let trainingData = try LipTakeMeta.encoder.encode(training)
        XCTAssertEqual(try LipTakeMeta.decoder.decode(LipJob.self, from: trainingData), training)
    }
}
