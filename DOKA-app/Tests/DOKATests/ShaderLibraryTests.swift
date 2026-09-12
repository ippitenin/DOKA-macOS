import Metal
import XCTest
@testable import DOKA

/// Шейдеры панели «Аврора» собираются ОТДЕЛЬНЫМ шагом (scripts/build-shaders.sh):
/// SwiftPM .metal не компилирует, а build-tool-плагин ломает universal-сборку.
/// Значит metallib легко забыть перегенерить — тогда панель молча останется без
/// эффекта. Эти проверки — единственный автоматический гейт на этот случай.
final class ShaderLibraryTests: XCTestCase {

    func testMetallibIsBundled() {
        XCTAssertNotNil(
            Bundle.module.url(forResource: "default", withExtension: "metallib"),
            "default.metallib нет в бандле — прогоните scripts/build-shaders.sh"
        )
        XCTAssertTrue(DropShaders.isAvailable)
    }

    /// Имена функций зашиты в вызовах `ShaderLibrary` строками — опечатка
    /// в Swift или переименование в .metal иначе всплывут только на экране.
    func testShaderFunctionsExist() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "default", withExtension: "metallib"))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let names = try device.makeLibrary(URL: url).functionNames
        XCTAssertTrue(names.contains("dokaDropWave"), "функции волны нет: \(names)")
        XCTAssertTrue(names.contains("dokaDropDots"), "функции точек нет: \(names)")
        XCTAssertTrue(names.contains("dokaDropGlass"), "функции стекла нет: \(names)")
    }

    /// Минимальная версия macOS, объявленная пакетом (`platforms: [.macOS(.v15)]`).
    private static let deploymentTarget: UInt8 = 15

    /// Компилятор Metal ЗАШИВАЕТ минимальную версию macOS в заголовок metallib,
    /// и без `-mmacosx-version-min` берёт её из SDK сборочной машины. На Xcode 26
    /// это давало «нужна macOS 26»: на 14 и 15 `makeLibrary(URL:)` отказывался
    /// грузить библиотеку, `DropShaders.isAvailable` становился false, и «Аврора»
    /// с «Мини» показывали пустую капельку. Приложение не падало, в лог уходило
    /// одно предупреждение — фича была молча мертва у всех, кто не на 26.
    ///
    /// Ни сборка, ни остальные тесты этого не ловили: и CI, и разработка идут
    /// на macOS 26, где библиотека грузится нормально. Поэтому версию надо
    /// читать из файла, а не полагаться на успех загрузки.
    ///
    /// Формат заголовка: магия «MTLB», затем версии контейнера, и по смещению
    /// 12 — мажорная версия ОС одним байтом (0x0e = 14, 0x0f = 15, 0x1a = 26).
    func testMetallibTargetsTheDeploymentTarget() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "default", withExtension: "metallib"))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 16, "metallib короче заголовка")
        XCTAssertEqual(Array(data.prefix(4)), Array("MTLB".utf8), "это не metallib")

        let stamped = data[12]
        XCTAssertLessThanOrEqual(
            stamped, Self.deploymentTarget,
            "metallib собран под macOS \(stamped), а приложение поддерживает macOS "
            + "\(Self.deploymentTarget)+ — на более старых системах шейдеры молча не "
            + "загрузятся. Прогоните scripts/build-shaders.sh (в нём должен стоять "
            + "-mmacosx-version-min)."
        )
    }
}
