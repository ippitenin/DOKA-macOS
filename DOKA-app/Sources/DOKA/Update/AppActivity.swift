import Foundation

/// «Занята ли DOKA работой, которую нельзя оборвать». Один предикат на всё
/// приложение: перенос «Папки данных» (`AdvancedSettingsView.migrate`) и
/// установка обновления (`UpdateController`) ждут покоя от одних и тех же
/// четверых — у переноса и обновления одна беда: процесс, оборванный
/// посреди записи, теряет результат.
enum AppActivity {
    /// Снимок занятости. Чистое значение — тестируется без синглтонов.
    struct Snapshot: Equatable {
        /// Распознавание файла на странице «Транскрибация» или из библиотеки.
        var fileTranscription = false
        /// Запись или распознавание диктовки (`DictationController.isActive`).
        var dictation = false
        /// ИИ-анализ (облако или модель на Mac).
        var analysis = false
        /// Фоновая работа библиотеки: архивация звука, добор async-задач.
        var libraryWork = false

        var isBusy: Bool { fileTranscription || dictation || analysis || libraryWork }
    }

    @MainActor
    static var current: Snapshot {
        Snapshot(fileTranscription: FileTranscriptionController.shared.isTranscribing,
                 dictation: DictationController.isActive,
                 analysis: AnalysisController.shared.isRunning,
                 libraryWork: TranscriptHistoryStore.shared.hasBackgroundWork)
    }

    @MainActor
    static var isBusy: Bool { current.isBusy }
}
