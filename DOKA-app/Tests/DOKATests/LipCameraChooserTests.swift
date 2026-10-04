import XCTest
@testable import DOKA

/// Выбор камеры для губ.
///
/// Зачем: у MacBook с закрытой крышкой встроенная камера остаётся в списке,
/// но спит (`isSuspended`). Выбрав её, DOKA снимала бы «ничего» при каждой
/// диктовке, игнорируя рабочую внешнюю веб-камеру.
final class LipCameraChooserTests: XCTestCase {
    private func cam(builtIn: Bool, suspended: Bool = false) -> LipCameraCandidate {
        LipCameraCandidate(isBuiltIn: builtIn, isSuspended: suspended)
    }

    func testPrefersBuiltInCamera() {
        XCTAssertEqual(LipCameraChooser.pick([cam(builtIn: false), cam(builtIn: true)]), 1)
    }

    /// Крышка закрыта — спящая встроенная пропускается, берётся внешняя.
    func testSkipsSuspendedBuiltInCamera() {
        XCTAssertEqual(LipCameraChooser.pick([cam(builtIn: true, suspended: true), cam(builtIn: false)]), 1)
    }

    func testNoUsableCamera() {
        XCTAssertNil(LipCameraChooser.pick([cam(builtIn: true, suspended: true)]))
        XCTAssertNil(LipCameraChooser.pick([]))
    }
}
