import Darwin
import XCTest
@testable import DOKA

/// Какие файлы агент вправе отдать в `transcribe_file` (`AgentPathPolicy`):
/// данные DOKA закрыты при любом написании пути.
final class AgentPathPolicyTests: XCTestCase {
    private var sandbox: URL!
    private var dokaRoot: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPathPolicyTests-\(UUID().uuidString)", isDirectory: true)
        dokaRoot = sandbox.appendingPathComponent("DOKA/transcripts/rec", isDirectory: true)
        outside = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dokaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dokaRoot.appendingPathComponent("audio.m4a"))
        try Data("audio".utf8).write(to: outside.appendingPathComponent("meeting.m4a"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private var roots: [URL] { [sandbox.appendingPathComponent("DOKA", isDirectory: true)] }

    private func check(_ path: String, prefixDirectory: URL? = nil) -> AgentPathPolicy.Verdict {
        AgentPathPolicy.check(path: path, protectedRoots: roots, protectedPrefixDirectory: prefixDirectory)
    }

    func testOrdinaryFileIsAllowedWithRealPath() throws {
        let path = outside.appendingPathComponent("meeting.m4a").path
        guard case .allowed(let real) = check(path) else { return XCTFail("\(check(path))") }
        // Временная папка живёт за симлинком /var → /private/var: путь разрешён.
        XCTAssertTrue(real.hasSuffix("/Downloads/meeting.m4a"))
        XCTAssertEqual(AgentPathPolicy.fileID(real), AgentPathPolicy.fileID(path))
    }

    func testFileInsideDokaDataIsProtected() {
        XCTAssertEqual(check(dokaRoot.appendingPathComponent("audio.m4a").path), .protected)
    }

    func testDotDotAndSymlinkDoNotEscape() throws {
        let viaDots = outside.path + "/../DOKA/transcripts/rec/audio.m4a"
        XCTAssertEqual(check(viaDots), .protected)

        let fileLink = outside.appendingPathComponent("innocent.m4a")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: dokaRoot.appendingPathComponent("audio.m4a"))
        XCTAssertEqual(check(fileLink.path), .protected)

        let folderLink = outside.appendingPathComponent("folder")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: dokaRoot)
        XCTAssertEqual(check(folderLink.path + "/audio.m4a"), .protected)
    }

    /// APFS по умолчанию не различает регистр: другое написание того же пути
    /// — тот же файл, и он тоже закрыт.
    func testCaseVariantIsProtected() {
        let variant = dokaRoot.appendingPathComponent("audio.m4a").path
            .replacingOccurrences(of: "/DOKA/", with: "/doka/")
        guard FileManager.default.fileExists(atPath: variant) else {
            return  // регистрозависимый том: такого пути просто нет
        }
        XCTAssertEqual(check(variant), .protected)
    }

    func testMissingFolderAndFifo() throws {
        XCTAssertEqual(check(outside.appendingPathComponent("nope.m4a").path), .missing)
        XCTAssertEqual(check(outside.path), .notRegularFile)
        let fifo = outside.appendingPathComponent("pipe.wav").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertEqual(check(fifo), .notRegularFile)
    }

    /// Временные WAV диктовок (`doka-*`) во временной папке закрыты, чужие
    /// файлы рядом — нет.
    func testDictationTempFilesAreProtected() throws {
        try Data("wav".utf8).write(to: outside.appendingPathComponent("doka-rec-1.wav"))
        try Data("wav".utf8).write(to: outside.appendingPathComponent("voice.wav"))
        XCTAssertEqual(check(outside.appendingPathComponent("doka-rec-1.wav").path, prefixDirectory: outside), .protected)
        guard case .allowed = check(outside.appendingPathComponent("voice.wav").path, prefixDirectory: outside) else {
            return XCTFail("обычный файл во временной папке должен проходить")
        }
    }

    /// Настоящие папки DOKA входят в закрытые.
    func testDokaRootsCoverDataModelsAndLips() {
        let roots = AgentPathPolicy.dokaRoots.map(\.standardizedFileURL.path)
        XCTAssertTrue(roots.contains(AppDataFolder.defaultURL.standardizedFileURL.path))
        XCTAssertTrue(AppDataFolder.lipDataURL.path.hasPrefix(AppDataFolder.defaultURL.path))
        XCTAssertTrue(AppDataFolder.modelsURL.path.hasPrefix(AppDataFolder.defaultURL.path))
    }
}
