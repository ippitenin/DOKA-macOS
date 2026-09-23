import XCTest
@testable import DOKA

/// Сведения о системе для экрана анализа производительности.
///
/// Зачем: после отказа от Intel у `SystemInfo.processor` остался один источник —
/// `machdep.cpu.brand_string`. Прежний фолбэк `hw.perflevel0.name` на M-чипе
/// давал имя кластера ядер («Super») вместо имени чипа.
final class SystemInfoTests: XCTestCase {

    /// Приложение собирается только под arm64 — тесты тоже обязаны идти на нём.
    /// Упадёт, если кто-то вернёт x86_64-сборку или запустит тесты под Rosetta.
    func testRunsOnAppleSilicon() {
        #if !arch(arm64)
        XCTFail("DOKA поддерживает только Apple Silicon (arm64)")
        #endif
    }

    /// Имя процессора — имя чипа Apple, а не кластера ядер и не прочерк.
    func testProcessorIsAppleChip() {
        let processor = SystemInfo.current().processor
        XCTAssertTrue(processor.hasPrefix("Apple"), "неожиданное имя процессора: \(processor)")
    }
}
