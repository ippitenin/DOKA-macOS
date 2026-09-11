import XCTest
@testable import DOKA

/// Имена файлов и объединённые документы экспорта библиотеки.
final class LibraryExportTests: XCTestCase {
    func testSanitizedFileNameReplacesSeparators() {
        XCTAssertEqual(LibraryExport.sanitizedFileName("Встреча 12/09: итоги\\план"), "Встреча 12-09- итоги-план")
    }

    func testSanitizedFileNameStripsControlCharacters() {
        XCTAssertEqual(LibraryExport.sanitizedFileName("  Лекция\n1\t "), "Лекция-1")
    }

    func testSanitizedFileNameFallsBackForEmpty() {
        XCTAssertEqual(LibraryExport.sanitizedFileName(""), "transcript")
        XCTAssertEqual(LibraryExport.sanitizedFileName("   "), "transcript")
    }

    func testSanitizedFileNameIsLimited() {
        let long = String(repeating: "я", count: 200)
        XCTAssertEqual(LibraryExport.sanitizedFileName(long).count, LibraryExport.maxBaseNameLength)
    }

    /// Лимит APFS — в байтах: эмодзи-последовательность занимает 25 байт,
    /// и обрезка по символам дала бы имя, которое файловая система не примет.
    func testSanitizedFileNameIsLimitedInBytesWithoutSplittingCharacters() {
        let family = "👨‍👩‍👧‍👦"
        let result = LibraryExport.sanitizedFileName(String(repeating: family, count: 80))
        XCTAssertLessThanOrEqual(result.utf8.count, LibraryExport.maxBaseNameBytes)
        XCTAssertEqual(result, String(repeating: family, count: LibraryExport.maxBaseNameBytes / family.utf8.count))
    }

    func testUniqueNameDeduplicates() {
        var taken: Set<String> = []
        XCTAssertEqual(LibraryExport.uniqueName(base: "Встреча", ext: "srt", taken: &taken), "Встреча.srt")
        XCTAssertEqual(LibraryExport.uniqueName(base: "Встреча", ext: "srt", taken: &taken), "Встреча (2).srt")
        XCTAssertEqual(LibraryExport.uniqueName(base: "Встреча", ext: "txt", taken: &taken), "Встреча.txt")
        XCTAssertEqual(LibraryExport.uniqueName(base: "Встреча", ext: "srt", taken: &taken), "Встреча (3).srt")
    }

    /// Уже лежащие в папке файлы не затираются, регистр не важен (APFS).
    func testUniqueNameRespectsExistingFilesCaseInsensitively() {
        var taken: Set<String> = ["отчёт.txt"]
        XCTAssertEqual(LibraryExport.uniqueName(base: "Отчёт", ext: "txt", taken: &taken), "Отчёт (2).txt")
    }

    func testCombinedMarkdown() {
        let entries = [
            LibraryExport.Entry(title: "Встреча", meta: "12 сент. · Nexara", text: "[0:00] Привет\n[0:05] Пока"),
            LibraryExport.Entry(title: "Лекция", meta: "", text: "Текст лекции")
        ]
        XCTAssertEqual(LibraryExport.combinedMarkdown(entries), """
        # Встреча

        *12 сент. · Nexara*

        [0:00] Привет

        [0:05] Пока

        ---

        # Лекция

        Текст лекции

        """)
    }

    func testCombinedPlainText() {
        let entries = [
            LibraryExport.Entry(title: "Встреча", meta: "12 сент.", text: "Привет"),
            LibraryExport.Entry(title: "Лекция", meta: "", text: "Текст")
        ]
        XCTAssertEqual(LibraryExport.combinedPlainText(entries), """
        Встреча
        12 сент.

        Привет

        ---

        Лекция

        Текст

        """)
    }
}
