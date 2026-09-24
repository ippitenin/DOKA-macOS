import XCTest
@testable import DOKA

/// Снимок параметров файловой транскрибации: гейты Nexara-полей считаются от
/// `providerID` снимка, а не от глобальной настройки. Разъедутся с
/// контроллером — «Распознать заново» отправит кастомному серверу `prompt`
/// (исказит транскрипцию) или потеряет спикеров. Сообщения
/// `SpeakerRolesParser` идут через L() — проверяется наличие, а не текст.
final class FileTranscriptionParamsTests: XCTestCase {

    private let customID = "custom:\(UUID().uuidString)"

    /// Параметры «всё включено»: каждое Nexara-поле не дефолтное, чтобы гейты
    /// было видно по результату.
    private func make(providerID: String = "builtin",
                      language: String = "ru",
                      diarize: Bool = true,
                      numSpeakers: Int? = 3,
                      diarizationSetting: String = DiarizationSetting.telephonic.rawValue,
                      rolesMode: String = RolesMode.custom.rawValue,
                      rolesText: String = "Клиент, Агент",
                      llmPreset: String = LLMAnalysisPreset.summary.rawValue,
                      llmCustomPrompt: String = "") -> FileTranscriptionParams {
        FileTranscriptionParams(providerID: providerID,
                                language: language,
                                diarize: diarize,
                                numSpeakers: numSpeakers,
                                diarizationSetting: diarizationSetting,
                                rolesMode: rolesMode,
                                rolesText: rolesText,
                                llmPreset: llmPreset,
                                llmCustomPrompt: llmCustomPrompt)
    }

    // MARK: - Встроенный сервис

    func testBuiltinPassesEverything() {
        let params = make()
        XCTAssertTrue(params.isBuiltin)
        XCTAssertFalse(params.isLocal)
        XCTAssertFalse(params.usesLocalDiarization)

        let options = params.makeOptions(detail: .fine)
        XCTAssertEqual(options.language, "ru")
        XCTAssertTrue(options.diarize)
        XCTAssertEqual(options.numSpeakers, 3)
        XCTAssertEqual(options.diarizationSetting, .telephonic)
        XCTAssertEqual(options.roles, .custom(["Клиент", "Агент"]))
        XCTAssertNotNil(options.llmPrompt)
        XCTAssertEqual(options.llmPrompt, LLMAnalysisPreset.summary.promptTemplate)
        XCTAssertEqual(options.timestampDetail, .fine)
    }

    func testBuiltinAutoRoles() {
        let params = make(rolesMode: RolesMode.auto.rawValue, rolesText: "")
        XCTAssertEqual(params.rolesSpec, .auto)
        XCTAssertNil(params.rolesValidationMessage)
    }

    func testBuiltinRolesNeedDiarization() {
        // Роли без диаризации не уходят и запуск не блокируют.
        let params = make(diarize: false, rolesText: " , ")
        XCTAssertEqual(params.rolesSpec, .none)
        XCTAssertNil(params.rolesValidationMessage)
        XCTAssertFalse(params.makeOptions(detail: .medium).diarize)
        XCTAssertFalse(params.usesLocalDiarization)
    }

    /// Анализ по шаблону уходит СНИМКОМ промпта: «Повторить» отправит ровно
    /// его, даже если шаблон потом изменят или удалят.
    func testTemplatePromptIsSnapshot() {
        var params = make(llmPreset: LLMAnalysisPreset.template.rawValue,
                          llmCustomPrompt: "  Снимок промпта шаблона \n")
        params.llmTemplateID = "builtin.summary"
        params.llmTemplateTitle = "Краткое резюме"
        XCTAssertEqual(params.effectiveLLMPrompt, "Снимок промпта шаблона")
        XCTAssertEqual(params.makeOptions(detail: .medium).llmPrompt, "Снимок промпта шаблона")

        // Не Nexara — промпт не уходит: у OpenAI-совместимых API это подсказка Whisper.
        params.providerID = customID
        XCTAssertNil(params.effectiveLLMPrompt)

        // «Распознать заново» — без анализа и без следов шаблона.
        let stripped = make(llmPreset: LLMAnalysisPreset.template.rawValue,
                            llmCustomPrompt: "x").withoutLLM()
        XCTAssertNil(stripped.effectiveLLMPrompt)
        XCTAssertNil(stripped.llmTemplateID)
        XCTAssertNil(stripped.llmTemplateTitle)
    }

    /// «На этом Mac»: в Nexara не уходит ни слова инструкции, даже на
    /// встроенном сервисе, — анализ сделает локальная модель после распознавания.
    func testLocalAnalysisSendsNoPrompt() {
        var params = make(llmPreset: LLMAnalysisPreset.custom.rawValue,
                          llmCustomPrompt: "Сделай выжимку")
        params.llmLocal = true
        XCTAssertTrue(params.isBuiltin)
        XCTAssertNil(params.effectiveLLMPrompt)
        XCTAssertNil(params.makeOptions(detail: .medium).llmPrompt)
        XCTAssertEqual(params.localAnalysisKind(templates: []), .custom("Сделай выжимку"))
        XCTAssertFalse(params.withoutLLM().llmLocal)
    }

    func testLocalAnalysisKindResolvesTemplate() {
        let templates = BuiltinAnalysisTemplate.all
        let chapters = BuiltinAnalysisTemplate.chapters.template
        var params = make(llmPreset: LLMAnalysisPreset.template.rawValue)
        params.llmTemplateID = chapters.id
        params.llmLocal = true
        XCTAssertEqual(params.localAnalysisKind(templates: templates), .template(chapters))

        // Шаблон удалили — анализ не заказан, а не «какой-нибудь другой».
        params.llmTemplateID = "deleted-template"
        XCTAssertNil(params.localAnalysisKind(templates: templates))

        // Облачный анализ локальную модель не запускает.
        params.llmTemplateID = chapters.id
        params.llmLocal = false
        XCTAssertNil(params.localAnalysisKind(templates: templates))

        // Пустой свой запрос и «Выкл» — тоже ничего.
        var blank = make(llmPreset: LLMAnalysisPreset.custom.rawValue, llmCustomPrompt: "  ")
        blank.llmLocal = true
        XCTAssertNil(blank.localAnalysisKind(templates: templates))
        var off = make(llmPreset: LLMAnalysisPreset.off.rawValue)
        off.llmLocal = true
        XCTAssertNil(off.localAnalysisKind(templates: templates))
    }

    // MARK: - Сборка полей анализа со страницы

    func testLLMFieldsLocalTemplateCarriesIDNotPrompt() {
        let chapters = BuiltinAnalysisTemplate.chapters.template
        // Хвост прошлого «Своего запроса» в снимок не попадает.
        let fields = FileTranscriptionParams.llmFields(preset: .template,
                                                       customPrompt: "старый запрос",
                                                       template: chapters, local: true,
                                                       languageName: "Русский")
        XCTAssertEqual(fields, .init(preset: .template, prompt: "",
                                     templateID: chapters.id, templateTitle: chapters.name))
    }

    func testLLMFieldsCloudTemplateIsPromptSnapshot() {
        let summary = BuiltinAnalysisTemplate.summary.template
        let fields = FileTranscriptionParams.llmFields(preset: .template, customPrompt: "",
                                                       template: summary, local: false,
                                                       languageName: "English")
        XCTAssertEqual(fields.prompt,
                       AnalysisPromptBuilder.nexaraPrompt(template: .sections(summary),
                                                          languageName: "English"))
        XCTAssertFalse(fields.prompt.isEmpty)
        XCTAssertEqual(fields.templateID, summary.id)
        XCTAssertEqual(fields.templateTitle, summary.name)
    }

    /// Шаблон удалили, пока он был выбран: анализ выключен, а не отправлен
    /// с пустым промптом — и локально, и в облако.
    func testLLMFieldsDeletedTemplateTurnsAnalysisOff() {
        for local in [true, false] {
            let fields = FileTranscriptionParams.llmFields(preset: .template, customPrompt: "x",
                                                           template: nil, local: local,
                                                           languageName: "Русский")
            XCTAssertEqual(fields, .init(preset: .off, prompt: ""))
        }
    }

    func testLLMFieldsCustomAndOffPassThrough() {
        let custom = FileTranscriptionParams.llmFields(preset: .custom, customPrompt: "Выжимка",
                                                       template: nil, local: false,
                                                       languageName: "Русский")
        XCTAssertEqual(custom, .init(preset: .custom, prompt: "Выжимка"))
        let off = FileTranscriptionParams.llmFields(preset: .off, customPrompt: "",
                                                    template: nil, local: true,
                                                    languageName: "Русский")
        XCTAssertEqual(off.preset, .off)
        XCTAssertNil(off.templateID)
    }

    /// Прежние пресеты из UI убраны, но записи библиотеки с ними повторяются
    /// тем же промптом.
    func testLegacyPresetStillHasPrompt() {
        let legacy = make(llmPreset: LLMAnalysisPreset.meetingMinutes.rawValue)
        XCTAssertEqual(legacy.effectiveLLMPrompt, LLMAnalysisPreset.meetingMinutes.promptTemplate)
        XCTAssertNotNil(legacy.effectiveLLMPrompt)
    }

    func testCustomPromptIsTrimmedAndEmptyMeansOff() {
        let custom = make(llmPreset: LLMAnalysisPreset.custom.rawValue,
                          llmCustomPrompt: "  Сделай выжимку \n")
        XCTAssertEqual(custom.effectiveLLMPrompt, "Сделай выжимку")

        let blank = make(llmPreset: LLMAnalysisPreset.custom.rawValue, llmCustomPrompt: " \n\t")
        XCTAssertNil(blank.effectiveLLMPrompt)

        let off = make(llmPreset: LLMAnalysisPreset.off.rawValue)
        XCTAssertNil(off.effectiveLLMPrompt)
    }

    // MARK: - Невалидные роли

    func testInvalidCustomRolesBlockAndFallBackToNone() {
        let empty = make(rolesText: " , ,")
        XCTAssertNotNil(empty.rolesValidationMessage)
        XCTAssertEqual(empty.rolesSpec, .none)
        XCTAssertEqual(empty.makeOptions(detail: .medium).roles, .none)

        let tooMany = make(rolesText: (1...11).map { "Роль\($0)" }.joined(separator: ","))
        XCTAssertNotNil(tooMany.rolesValidationMessage)
        XCTAssertEqual(tooMany.rolesSpec, .none)

        let duplicate = make(rolesText: "Клиент, клиент")
        XCTAssertNotNil(duplicate.rolesValidationMessage)
        XCTAssertEqual(duplicate.rolesSpec, .none)
    }

    // MARK: - Кастомный сетевой сервис

    func testCustomServiceStripsNexaraFields() {
        let params = make(providerID: customID)
        XCTAssertFalse(params.isBuiltin)
        XCTAssertFalse(params.isLocal)
        // Спикеров считает локальный диаризатор, подсказка числа — сырое поле.
        XCTAssertTrue(params.usesLocalDiarization)
        XCTAssertEqual(params.numSpeakers, 3)

        let options = params.makeOptions(detail: .coarse)
        XCTAssertEqual(options.language, "ru")
        XCTAssertFalse(options.diarize)
        XCTAssertNil(options.numSpeakers)
        XCTAssertEqual(options.diarizationSetting, .general)
        XCTAssertEqual(options.roles, .none)
        XCTAssertNil(options.llmPrompt)
        XCTAssertEqual(options.timestampDetail, .coarse)
    }

    func testCustomServiceIgnoresInvalidRolesAndCustomPrompt() {
        // Роли и промпт в запрос не попадут — значит, и запуск не блокируют.
        let params = make(providerID: customID,
                          rolesText: " , ",
                          llmPreset: LLMAnalysisPreset.custom.rawValue,
                          llmCustomPrompt: "Сделай выжимку")
        XCTAssertNil(params.rolesValidationMessage)
        XCTAssertEqual(params.rolesSpec, .none)
        XCTAssertNil(params.effectiveLLMPrompt)
    }

    func testCustomServiceWithoutDiarizationNeedsNoLocalDiarizer() {
        XCTAssertFalse(make(providerID: customID, diarize: false).usesLocalDiarization)
    }

    // MARK: - Локальные модели

    func testLocalModelsAreLocalAndGetNoNexaraFields() {
        for model in LocalModel.allCases {
            let params = make(providerID: model.providerID)
            XCTAssertTrue(params.isLocal, model.rawValue)
            XCTAssertFalse(params.isBuiltin, model.rawValue)
            XCTAssertTrue(params.usesLocalDiarization, model.rawValue)
            XCTAssertNil(params.rolesValidationMessage, model.rawValue)
            XCTAssertNil(params.effectiveLLMPrompt, model.rawValue)

            let options = params.makeOptions(detail: .medium)
            XCTAssertFalse(options.diarize, model.rawValue)
            XCTAssertNil(options.numSpeakers, model.rawValue)
            XCTAssertEqual(options.diarizationSetting, .general, model.rawValue)
            XCTAssertEqual(options.roles, .none, model.rawValue)
            XCTAssertNil(options.llmPrompt, model.rawValue)
        }
    }

    func testUnknownLocalModelIsNotLocal() {
        XCTAssertFalse(make(providerID: "local:unknown").isLocal)
    }

    // MARK: - Язык

    func testAutoLanguageMeansNil() {
        XCTAssertNil(make(language: "auto").makeOptions(detail: .medium).language)
        XCTAssertNil(make(providerID: customID, language: "auto").makeOptions(detail: .medium).language)
        XCTAssertEqual(make(language: "en").makeOptions(detail: .medium).language, "en")
    }

    // MARK: - withoutLLM

    func testWithoutLLMDropsOnlyAnalysis() {
        let params = make(llmPreset: LLMAnalysisPreset.custom.rawValue, llmCustomPrompt: "Сделай выжимку")
        let stripped = params.withoutLLM()

        XCTAssertEqual(stripped.llmPreset, LLMAnalysisPreset.off.rawValue)
        XCTAssertEqual(stripped.llmCustomPrompt, "")
        XCTAssertNil(stripped.effectiveLLMPrompt)
        XCTAssertNil(stripped.makeOptions(detail: .medium).llmPrompt)

        var expected = params
        expected.llmPreset = LLMAnalysisPreset.off.rawValue
        expected.llmCustomPrompt = ""
        XCTAssertEqual(stripped, expected)
        // Диаризация и роли остаются как были.
        XCTAssertEqual(stripped.rolesSpec, .custom(["Клиент", "Агент"]))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let values = [
            make(),
            make(providerID: customID, numSpeakers: nil),
            make(providerID: LocalModel.parakeet.providerID, language: "auto", diarize: false,
                 llmPreset: LLMAnalysisPreset.custom.rawValue, llmCustomPrompt: "Промпт \"в кавычках\""),
            FileTranscriptionParams(providerID: "builtin", language: "auto", diarize: false,
                                    numSpeakers: nil, diarizationSetting: "general",
                                    rolesMode: "off", rolesText: "",
                                    llmPreset: LLMAnalysisPreset.template.rawValue,
                                    llmCustomPrompt: "Снимок", llmTemplateID: "builtin.chapters",
                                    llmTemplateTitle: "Главы", llmLocal: true)
        ]
        for original in values {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FileTranscriptionParams.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    func testDecodeMissingFieldsGivesDefaults() throws {
        let expected = FileTranscriptionParams(providerID: "builtin",
                                               language: "auto",
                                               diarize: false,
                                               numSpeakers: nil,
                                               diarizationSetting: DiarizationSetting.general.rawValue,
                                               rolesMode: RolesMode.off.rawValue,
                                               rolesText: "",
                                               llmPreset: LLMAnalysisPreset.off.rawValue,
                                               llmCustomPrompt: "")

        let onlyProvider = try JSONDecoder().decode(FileTranscriptionParams.self,
                                                    from: Data(#"{"providerID":"builtin"}"#.utf8))
        XCTAssertEqual(onlyProvider, expected)

        let empty = try JSONDecoder().decode(FileTranscriptionParams.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, expected)

        // null в опциональном поле — тоже дефолт, а не ошибка.
        let nulls = try JSONDecoder().decode(FileTranscriptionParams.self,
                                             from: Data(#"{"numSpeakers":null,"language":null}"#.utf8))
        XCTAssertEqual(nulls, expected)
    }

    func testDecodeUnknownRawValuesFallsBackWithoutThrowing() throws {
        let json = #"""
        {"providerID":"builtin","diarize":true,"diarizationSetting":"meeting",
         "rolesMode":"magic","llmPreset":"poem","llmCustomPrompt":"x"}
        """#
        let params = try JSONDecoder().decode(FileTranscriptionParams.self, from: Data(json.utf8))

        XCTAssertEqual(params.diarizationSettingValue, .general)
        XCTAssertEqual(params.rolesModeValue, .off)
        XCTAssertEqual(params.llmPresetValue, .off)
        XCTAssertEqual(params.rolesSpec, .none)
        XCTAssertNil(params.effectiveLLMPrompt)
        XCTAssertNil(params.rolesValidationMessage)
        XCTAssertEqual(params.makeOptions(detail: .medium).diarizationSetting, .general)
        // Сырые строки сохраняются как есть — повторная запись их не теряет.
        XCTAssertEqual(params.diarizationSetting, "meeting")
        XCTAssertEqual(params.rolesMode, "magic")
        XCTAssertEqual(params.llmPreset, "poem")
    }
}
