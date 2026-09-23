import XCTest
@testable import DOKA

/// Инварианты локальных ресурсов: идентификаторы сервисов и пути на диске.
///
/// Зачем: весь каталог `Local/` — самый свежий код в проекте и до сих пор
/// не покрыт ничем. Здесь закрепляется то, что ломается молча и дорого:
/// формат `providerID` (ошибка разбора = тихий уход на ПЛАТНЫЙ сервис),
/// имя папки Parakeet (FluidAudio срезает последний компонент пути — из-за
/// этого «Удалить модель» однажды уже была no-op).
final class LocalModelTests: XCTestCase {

    // MARK: - providerID

    /// `"local:<rawValue>"` — третий формат рядом с `"builtin"` и
    /// `"custom:<uuid>"`. Round-trip обязан быть точным.
    func testProviderIDRoundTrips() {
        for model in LocalModel.allCases {
            XCTAssertEqual(LocalModel.from(providerID: model.providerID), model)
        }
    }

    func testProviderIDFormat() {
        XCTAssertEqual(LocalModel.whisper.providerID, "local:whisper")
        XCTAssertEqual(LocalModel.parakeet.providerID, "local:parakeet")
    }

    /// Всё, что не начинается с `local:`, локальным НЕ является — иначе
    /// запрос ушёл бы не туда, а пользователь заплатил бы за диктовку.
    func testNonLocalProviderIDsAreRejected() {
        for raw in ["builtin", "custom:1234", "", "whisper", "parakeet",
                    "local", "LOCAL:whisper", " local:whisper"] {
            XCTAssertNil(LocalModel.from(providerID: raw), "принят как локальный: «\(raw)»")
        }
    }

    /// Неизвестная локальная модель (запись из будущей версии) — не локальная,
    /// а не крэш и не подстановка первой попавшейся.
    func testUnknownLocalModelIsNotLocal() {
        XCTAssertNil(LocalModel.from(providerID: "local:canary"))
        XCTAssertNil(LocalModel.from(providerID: "local:"))
    }

    // MARK: - Имена

    /// `title` уезжает в метаданные истории через `providerTagForHistory`,
    /// поэтому его форма — контракт, а не оформление.
    func testTitleIsDerivedFromPlainTitle() {
        for model in LocalModel.allCases {
            XCTAssertEqual(model.title, "\(model.plainTitle) (Local)")
        }
        XCTAssertEqual(LocalModel.whisper.title, "Whisper Large v3 Turbo (Local)")
        XCTAssertEqual(LocalModel.parakeet.title, "Parakeet TDT 0.6B v3 (Local)")
    }

    /// Имя модели для поля `model` записей истории и анализа производительности.
    func testModelNamesMatchActualModels() {
        XCTAssertEqual(LocalModel.whisper.modelName, "whisper-large-v3-turbo")
        XCTAssertEqual(LocalModel.parakeet.modelName, "parakeet-tdt-0.6b-v3")
    }

    /// У Parakeet нет варианта «Turbo» — в отличие от Whisper, где v20240930
    /// и есть turbo-релиз. Подпись не должна обещать несуществующее.
    func testOnlyWhisperIsCalledTurbo() {
        XCTAssertTrue(LocalModel.whisper.plainTitle.contains("Turbo"))
        XCTAssertFalse(LocalModel.parakeet.plainTitle.contains("Turbo"))
    }

    // MARK: - LocalAsset

    /// `allCases` — вход для sweep и для подсчёта занятого места. Ресурс,
    /// забытый здесь, оставит гигабайты мусора в Application Support.
    func testAllAssetsCoverEverySpeechModelPlusDiarizerAndLLM() {
        let all = LocalAsset.allCases
        XCTAssertEqual(all.count, LocalModel.allCases.count + 2)
        for model in LocalModel.allCases {
            XCTAssertTrue(all.contains(.speech(model)), "нет .speech(\(model.rawValue))")
        }
        XCTAssertTrue(all.contains(.diarizer))
        XCTAssertTrue(all.contains(.llm))
    }

    /// Диаризатор и языковая модель — НЕ сервисы распознавания: попав в
    /// `LocalModel`, они оказались бы в пикере «Сервис» и в `providerID`.
    func testOnlySpeechModelsAreServices() {
        XCTAssertEqual(Set(LocalModel.allCases.map(\.rawValue)), ["whisper", "parakeet"])
    }

    func testApproximateSizesAreSane() {
        for asset in LocalAsset.allCases {
            XCTAssertGreaterThan(asset.approxDownloadBytes, 0, "\(asset.logName): размер не задан")
        }
        XCTAssertEqual(LocalAsset.llm.approxDownloadBytes, LLMModelSpec.current.bytes)
        XCTAssertEqual(LocalAsset.speech(.whisper).approxDownloadBytes,
                       LocalModel.whisper.approxDownloadBytes)
    }

    func testLogNamesAreDistinct() {
        let names = LocalAsset.allCases.map(\.logName)
        XCTAssertEqual(Set(names).count, names.count, "имена для логов дублируются: \(names)")
    }

    // MARK: - Пути на диске

    /// Ловушка FluidAudio: у ASR переданный путь теряет последний компонент и
    /// получает вместо него имя репозитория. Пока папка называлась
    /// `Models/parakeet`, её фактически не существовало: размер показывался
    /// нулевым, а «Удалить модель» было no-op. Имя обязано совпадать с
    /// репозиторием модели.
    func testParakeetFolderIsNamedAfterTheRepository() {
        XCTAssertEqual(LocalModelStore.parakeetFolder.lastPathComponent, "parakeet-tdt-0.6b-v3")
    }

    /// У офлайнового диаризатора наоборот: путь идёт как есть, а репозиторий
    /// создаётся ВНУТРИ него.
    func testDiarizerModelFolderLivesInsideDiarizerFolder() {
        XCTAssertEqual(LocalModelStore.diarizerFolder.lastPathComponent, "diarizer")
        XCTAssertEqual(LocalModelStore.diarizerModelFolder.deletingLastPathComponent().path,
                       LocalModelStore.diarizerFolder.path)
    }

    /// Все ресурсы лежат в ФИКСИРОВАННОЙ папке моделей и НЕ следуют за
    /// пользовательской «Папкой данных»: это перекачиваемый кеш, а перенос
    /// полутора гигабайт сделал бы миграцию блокирующей.
    func testEveryAssetLivesUnderTheFixedModelsFolder() {
        let root = AppDataFolder.modelsURL.path
        for path in [LocalModelStore.whisperBase.path,
                     LocalModelStore.whisperModelFolder.path,
                     LocalModelStore.parakeetFolder.path,
                     LocalModelStore.diarizerFolder.path,
                     LocalModelStore.diarizerModelFolder.path,
                     LocalModelStore.llmFolder.path,
                     LocalModelStore.llmFile.path] {
            XCTAssertTrue(path.hasPrefix(root + "/"), "вне папки моделей: \(path)")
        }
        XCTAssertEqual(URL(fileURLWithPath: root).lastPathComponent, "Models")
    }

    func testLLMFileIsNamedAfterCurrentSpec() {
        XCTAssertEqual(LocalModelStore.llmFile.lastPathComponent, LLMModelSpec.current.fileName)
        XCTAssertEqual(LocalModelStore.llmFile.deletingLastPathComponent().path,
                       LocalModelStore.llmFolder.path)
    }

    /// Папки разных ресурсов не должны вкладываться друг в друга: удаление
    /// одной снесло бы другую.
    func testAssetFoldersDoNotNest() {
        let folders = [LocalModelStore.whisperBase.path,
                       LocalModelStore.parakeetFolder.path,
                       LocalModelStore.diarizerFolder.path,
                       LocalModelStore.llmFolder.path]
        for outer in folders {
            for inner in folders where inner != outer {
                XCTAssertFalse(inner.hasPrefix(outer + "/"), "\(inner) лежит внутри \(outer)")
            }
        }
    }

    // MARK: - Спека языковой модели

    /// Смена модели — это смена `current`; спека обязана быть заполненной,
    /// иначе скачивание уйдёт в никуда или не сойдётся хэш.
    func testCurrentLLMSpecIsComplete() {
        let spec = LLMModelSpec.current
        XCTAssertFalse(spec.id.isEmpty)
        XCTAssertFalse(spec.fileName.isEmpty)
        XCTAssertEqual(spec.sha256.count, 64, "sha256 должен быть 64 hex-символа")
        XCTAssertTrue(spec.sha256.allSatisfy { $0.isHexDigit })
        XCTAssertGreaterThan(spec.bytes, 0)
        XCTAssertEqual(spec.url.scheme, "https")
    }

    /// Пин РЕВИЗИИ, а не `main`: содержимое `main` меняется, и хэш перестал
    /// бы сходиться на ровном месте.
    func testLLMURLPinsARevision() {
        XCTAssertFalse(LLMModelSpec.current.url.path.contains("/resolve/main/"),
                       "ссылка на main — хэш перестанет сходиться при обновлении репозитория")
    }

    /// Окно контекста на маке с малой ОЗУ вдвое короче: длинное окно вместе
    /// с вычислительными буферами уводит систему в своп.
    func testContextLimitNeverExceedsMaxContext() {
        let spec = LLMModelSpec.current
        XCTAssertLessThanOrEqual(spec.contextLimit, spec.maxContext)
        XCTAssertGreaterThan(spec.contextLimit, 0)
        XCTAssertLessThan(LLMModelSpec.lowMemoryContext, spec.maxContext)
    }

    /// Фиксированное зерно: «Повторить» без правок обязано давать тот же
    /// отчёт, иначе пользователь не отличит регресс от случайности.
    func testSamplingSeedIsFixed() {
        XCTAssertNotEqual(LLMModelSpec.current.sampling.seed, 0)
    }

    /// Гибридная thinking-модель: пустой блок `<think></think>` выключает
    /// размышления. Без него модель тратит минуты на текст, который мы
    /// всё равно вырезаем.
    func testAssistantPrefillDisablesThinking() {
        let prefill = try? XCTUnwrap(LLMModelSpec.current.assistantPrefill)
        XCTAssertTrue(prefill?.contains("<think>") == true)
        XCTAssertTrue(prefill?.contains("</think>") == true)
    }
}
