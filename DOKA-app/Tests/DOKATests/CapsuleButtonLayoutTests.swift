import AppKit
import SwiftUI
import XCTest
@testable import DOKA

/// Вёрстка капсульных кнопок (`dsGlassButton`/`dsProminentButton`). Баг, ради
/// которого тест заведён: в «Сервисе» при скачивании модели с двузначного
/// процента «Отмена» переносилась по буквам («Отмен/а») — HStack строки
/// настроек отдавал ряду меньше, чем тот просил, хотя слева было пусто.
@MainActor
final class CapsuleButtonLayoutTests: XCTestCase {

    /// Ряд скачивания в строке настроек — при любой ширине карточки ровно
    /// одна строка: высота та же, что у ряда в заведомо широком окне.
    func testCancelNeverWrapsInSettingsRow() {
        let reference = downloadRowSize(progress: 0.47, width: 2000)
        XCTAssertGreaterThan(reference.height, 0, "ряд не измерился")
        for width in stride(from: 380, through: 900, by: 10) {
            for progress in [0.07, 0.22, 0.47, 0.99, 1.0] {
                let size = downloadRowSize(progress: progress, width: CGFloat(width))
                XCTAssertEqual(size.height, reference.height, accuracy: 0.5,
                               "ширина \(width), \(Int(progress * 100)) %: ряд в две строки")
            }
        }
    }

    /// Процент занимает место под «100 %» всегда: полоса не прыгает влево,
    /// когда число становится двузначным и трёхзначным.
    func testRowWidthDoesNotDependOnPercent() {
        let widths = [0.07, 0.47, 1.0].map { downloadRowSize(progress: $0, width: 2000).width }
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.5)
    }

    /// Кнопка во всю ширину (`.frame(maxWidth: .infinity)` в подписи — «Новый
    /// шаблон», «Показать в Finder») по-прежнему растягивается.
    func testFullWidthButtonStillStretches() {
        let size = measure(width: 300) { box in
            Button {} label: {
                Label("Новый шаблон", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .dsGlassButton()
            .background(SizeProbe(box: box))
        }
        XCTAssertEqual(size.width, 300, accuracy: 0.5)
    }

    /// Обычная кнопка не растягивается на всё предложенное место.
    func testPlainButtonKeepsItsWidth() {
        let size = measure(width: 600) { box in
            HStack {
                Button("Отмена") {}
                    .dsGlassButton()
                    .background(SizeProbe(box: box))
                Spacer(minLength: 0)
            }
        }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThan(size.width, 150)
    }

    // MARK: - Стенд

    private func downloadRowSize(progress: Double, width: CGFloat) -> CGSize {
        measure(width: width) { box in
            SettingsRow(title: "Модель анализа:", help: "Подсказка") {
                DownloadProgressRow(progress: progress) {}
                    .background(SizeProbe(box: box))
            }
        }
    }

    private func measure<Content: View>(width: CGFloat,
                                        @ViewBuilder _ content: (SizeBox) -> Content) -> CGSize {
        let box = SizeBox()
        let host = NSHostingView(rootView: content(box).frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        return box.size
    }
}

private final class SizeBox {
    var size: CGSize = .zero
}

/// Записывает размер вью, на которую повешен фоном: тело GeometryReader
/// считается на проходе раскладки `layoutSubtreeIfNeeded`, окно не нужно.
private struct SizeProbe: View {
    let box: SizeBox

    var body: some View {
        GeometryReader { proxy in
            box.size = proxy.size
            return Color.clear
        }
    }
}
