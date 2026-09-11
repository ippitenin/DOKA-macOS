import Foundation

/// Снимок параметров запуска файловой транскрибации: всё, что пользователь
/// выбрал на странице перед запуском, плюс сервис, которым распознавали.
/// Нужен, чтобы (а) сохранить параметры в записи библиотеки и (б) повторить
/// распознавание по ним же, НЕ завися от глобального `SettingsStore.providerID`
/// (пользователь мог с тех пор переключить сервис).
///
/// Гейты Nexara-специфичных параметров — те же, что в `FileTranscriptionController`
/// (`isBuiltinService`, `usesLocalDiarization`, `rolesSpec`, `effectiveLLMPrompt`),
/// но считаются от `providerID` снимка, а не от текущей настройки.
///
/// Перечисления хранятся СЫРЫМИ строками (`rawValue`): переименование или
/// удаление кейса не должно ронять декод библиотеки — неизвестное значение
/// просто падает на дефолт в вычисляемых `*Value`.
struct FileTranscriptionParams: Codable, Equatable {
    var providerID: String            // "builtin" | "custom:<uuid>" | "local:whisper" | "local:parakeet"
    var language: String              // "auto" | код
    var diarize: Bool
    var numSpeakers: Int?
    var diarizationSetting: String    // DiarizationSetting.rawValue — сырые строки: переименование кейса не должно ронять декод библиотеки
    var rolesMode: String             // RolesMode.rawValue
    var rolesText: String
    var llmPreset: String             // LLMAnalysisPreset.rawValue
    var llmCustomPrompt: String
}

// MARK: - Гейты сервиса

extension FileTranscriptionParams {
    /// Встроенный сервис (Nexara): только ему уходят `task=diarize`,
    /// `num_speakers`, `diarization_setting`, `roles` и `prompt` — у кастомных
    /// OpenAI-совместимых API таких полей нет, строгий сервер ответит 400.
    var isBuiltin: Bool {
        providerID == TranscriptionProvider.builtin.rawValue
    }

    /// Локальная модель (on-device, без сети и ключа).
    var isLocal: Bool {
        LocalModel.from(providerID: providerID) != nil
    }

    /// Разделение по спикерам считается на этом Mac: у локальных моделей
    /// сервера нет вовсе, у пользовательских OpenAI-совместимых сервисов
    /// диаризации нет в API. Подсказка о числе спикеров для локального
    /// диаризатора — сырое `numSpeakers` (в `makeOptions` оно срезается
    /// только для запроса к серверу).
    var usesLocalDiarization: Bool {
        diarize && !isBuiltin
    }

    /// Тип записи; неизвестное сохранённое значение — `.general`.
    var diarizationSettingValue: DiarizationSetting {
        DiarizationSetting(rawValue: diarizationSetting) ?? .general
    }

    /// Режим ролей; неизвестное сохранённое значение — `.off`.
    var rolesModeValue: RolesMode {
        RolesMode(rawValue: rolesMode) ?? .off
    }

    /// Пресет анализа; неизвестное сохранённое значение — `.off`.
    var llmPresetValue: LLMAnalysisPreset {
        LLMAnalysisPreset(rawValue: llmPreset) ?? .off
    }
}

// MARK: - Сборка запроса

extension FileTranscriptionParams {
    /// Ошибка валидации своего списка ролей; nil — всё валидно (или роли
    /// в запрос не попадут вовсе). Не-nil должен блокировать запуск.
    var rolesValidationMessage: String? {
        guard diarize, isBuiltin, rolesModeValue == .custom else { return nil }
        if case .failure(let error) = SpeakerRolesParser.parse(rolesText) {
            return error.message
        }
        return nil
    }

    /// Разметка ролей для запроса с учётом гейтов (builtin + диаризация).
    /// Невалидный свой список даёт `.none` — запуск при этом всё равно
    /// заблокирован `rolesValidationMessage`.
    var rolesSpec: RolesSpec {
        guard diarize, isBuiltin else { return .none }
        switch rolesModeValue {
        case .off:
            return .none
        case .auto:
            return .auto
        case .custom:
            guard case .success(let names) = SpeakerRolesParser.parse(rolesText) else { return .none }
            return .custom(names)
        }
    }

    /// Итоговый промпт LLM-анализа; nil — анализ выключен или недоступен.
    /// Жёсткий гейт builtin: у кастомных OpenAI-совместимых API `prompt` —
    /// контекстная подсказка Whisper, LLM-инструкция там молча исказила бы
    /// транскрипцию.
    var effectiveLLMPrompt: String? {
        guard isBuiltin else { return nil }
        let preset = llmPresetValue
        switch preset {
        case .off:
            return nil
        case .custom:
            let trimmed = llmCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .meetingMinutes, .summary, .actionItems:
            return preset.promptTemplate
        }
    }

    /// Параметры запроса — ровно так, как их собирает
    /// `FileTranscriptionController.transcribe()`.
    func makeOptions(detail: TimestampDetail) -> FileTranscriptionOptions {
        FileTranscriptionOptions(
            language: language == "auto" ? nil : language,
            // На сервер `task=diarize` уходит ТОЛЬКО встроенному: у кастомных
            // OpenAI-совместимых API такого режима нет. Им спикеров проставит
            // локальный диаризатор (`usesLocalDiarization`).
            diarize: diarize && isBuiltin,
            numSpeakers: isBuiltin ? numSpeakers : nil,
            diarizationSetting: isBuiltin ? diarizationSettingValue : .general,
            roles: rolesSpec,
            llmPrompt: effectiveLLMPrompt,
            timestampDetail: detail
        )
    }

    /// Копия без LLM-анализа — для «Распознать заново»: анализ — отдельное
    /// действие, а повторный запрос с `prompt` снова тарифицировал бы его
    /// у Nexara.
    func withoutLLM() -> FileTranscriptionParams {
        var copy = self
        copy.llmPreset = LLMAnalysisPreset.off.rawValue
        copy.llmCustomPrompt = ""
        return copy
    }
}

// MARK: - Декод

extension FileTranscriptionParams {
    /// Каждое поле — `decodeIfPresent` с дефолтом: запись библиотеки не должна
    /// теряться из-за ключа, которого не было в старой версии формата.
    /// Объявлен в расширении, чтобы у структуры остался memberwise-init.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
            ?? TranscriptionProvider.builtin.rawValue
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? false
        numSpeakers = try c.decodeIfPresent(Int.self, forKey: .numSpeakers)
        diarizationSetting = try c.decodeIfPresent(String.self, forKey: .diarizationSetting)
            ?? DiarizationSetting.general.rawValue
        rolesMode = try c.decodeIfPresent(String.self, forKey: .rolesMode) ?? RolesMode.off.rawValue
        rolesText = try c.decodeIfPresent(String.self, forKey: .rolesText) ?? ""
        llmPreset = try c.decodeIfPresent(String.self, forKey: .llmPreset)
            ?? LLMAnalysisPreset.off.rawValue
        llmCustomPrompt = try c.decodeIfPresent(String.self, forKey: .llmCustomPrompt) ?? ""
    }
}
