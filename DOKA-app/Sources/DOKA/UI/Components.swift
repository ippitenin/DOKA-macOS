import AppKit
import SwiftUI

/// Мост к NSVisualEffectView — честный системный материал
/// (SwiftUI-материалы не дают .behindWindow-блюра в ручном NSWindow).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Крупный заголовок секции контент-области.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Стеклянная карточка-группа (бывший grouped-стиль Системных настроек).
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        // Контент (например, List) обрезается по форме стекла.
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glassSurface()
    }
}

/// Иконка статуса шага (выполнен/не выполнен).
struct StatusIcon: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }
}

/// Строка шага настройки: статус, заголовок, описание, действия.
struct StepRow<Actions: View>: View {
    let done: Bool
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: done)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack { actions }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

/// Кнопка копирования текста с понятным фидбэком: после нажатия ~1.5 с
/// показывает «Скопировано» с галочкой, затем возвращается к «Скопировать».
/// Решает проблему «копирование без подтверждения» — видно, что сработало.
/// С `html` кладёт в буфер оба представления (plain + HTML) — приложения с
/// rich-вставкой (Telegram, Notes, Word) получат таблицы таблицами.
struct CopyButton: View {
    let text: String
    var html: String? = nil
    @State private var copied = false
    /// Счётчик нажатий — повторный клик перезапускает авто-возврат.
    @State private var copyCount = 0

    var body: some View {
        Button {
            if let html {
                ClipboardManager.setRichText(plain: text, html: html)
            } else {
                ClipboardManager.setString(text)
            }
            copyCount += 1
            withAnimation(DS.Anim.control) { copied = true }
        } label: {
            Label(
                copied ? L("common.copied") : L("common.copy"),
                systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
            )
            .font(.caption)
            .foregroundStyle(copied ? Color.green : DS.accent)
            .symbolEffect(.bounce, value: copied)
            .animation(DS.Anim.control, value: copied)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(L("common.copy"))
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Anim.control) { copied = false }
        }
    }
}

/// Бэйдж клавиши для отображения сочетаний («⌥», «⇥»).
struct KeyCapBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 28, weight: .medium, design: .rounded))
            .frame(minWidth: 52, minHeight: 52)
            .glassSurface(radius: DS.Radius.badge)
    }
}

/// Обёртка сворачивания длинного контента: показывает не более
/// `collapsedHeight`, нижние строки затухают в фон, снизу — кнопка «Развернуть».
/// В развёрнутом виде — контент целиком и кнопка «Свернуть». Кнопка появляется,
/// только если контент заметно выше порога. Один `collapsedHeight` на карточки
/// «Анализ» и «Результат» держит их примерно одного размера в свёрнутом виде.
struct CollapsibleReveal<Content: View>: View {
    var collapsedHeight: CGFloat = 160
    /// Отступ вокруг контента и снизу под кнопкой — обёртка владеет им сама,
    /// чтобы карточки «Анализ» и «Результат» выглядели одинаково, а кнопка
    /// не прилипала к краю. Места вызова отдают контент БЕЗ своего паддинга.
    var contentPadding: CGFloat = DS.Spacing.cardPadding
    @ViewBuilder var content: Content

    @State private var isExpanded = false
    @State private var contentHeight: CGFloat = 0

    /// Сворачивать имеет смысл, только если контент заметно выше порога —
    /// иначе пары лишних строк ради кнопки не стоит.
    private var isCollapsible: Bool { contentHeight > collapsedHeight + 24 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heightReader)
                .frame(maxHeight: (isCollapsible && !isExpanded) ? collapsedHeight : nil,
                       alignment: .top)
                .clipped()
                .mask(fadeMask)

            if isCollapsible {
                toggleButton
            }
        }
    }

    /// Меряет натуральную высоту контента до ограничения `frame(maxHeight:)`.
    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.height, initial: true) { _, newValue in
                    contentHeight = newValue
                }
        }
    }

    /// В свёрнутом виде нижние ~28% затухают к прозрачности, иначе маска сплошная.
    @ViewBuilder
    private var fadeMask: some View {
        if isCollapsible && !isExpanded {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            Rectangle().fill(.black)
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(DS.Anim.section) { isExpanded.toggle() }
        } label: {
            Label(isExpanded ? L("common.collapse") : L("common.expand"),
                  systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.bottom, contentPadding)
        .frame(maxWidth: .infinity)
    }
}

/// Статус скачиваемого локального ресурса: «Не скачана · ~1,6 ГБ» с кнопкой,
/// прогресс с отменой, «Подготовка модели…», «Скачана · N» с удалением.
/// Один и тот же ряд состояний нужен и карточке модели распознавания
/// в «Сервисе», и строке диаризатора на странице транскрибации — держим
/// его в одном месте, чтобы поведение и вид не разъезжались.
///
/// `name` подменяет слово-статус именем ресурса: там, где название модели над
/// строкой не показано (третий шаг онбординга), вместо «Не скачана · ~1,6 ГБ»
/// выводится «Whisper Large v3 Turbo · ~1,6 ГБ». По умолчанию nil — в
/// «Сервисе» и у диаризатора остаются слова статуса, как были.
struct LocalAssetStatusView: View {
    let asset: LocalAsset
    let name: String?

    @ObservedObject private var models = LocalModelStore.shared
    @State private var confirmDelete = false

    // Инициализатор явный: приватные свойства выше делают синтезированный
    // memberwise-init приватным, и вью нельзя было бы создать из других файлов.
    init(asset: LocalAsset, name: String? = nil) {
        self.asset = asset
        self.name = name
    }

    var body: some View {
        content
            .alert(L("service.local.deleteConfirmTitle"), isPresented: $confirmDelete) {
                Button(L("service.local.deleteModel"), role: .destructive) {
                    models.delete(asset)
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("service.local.deleteConfirmText"))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch models.state(for: asset) {
        case .notDownloaded:
            HStack(spacing: 12) {
                Text(name.map { L("service.local.namedApprox", $0, Self.bytes(asset.approxDownloadBytes)) }
                     ?? L("service.local.notDownloaded", Self.bytes(asset.approxDownloadBytes)))
                    .foregroundStyle(.secondary)
                Button(L("service.local.download")) {
                    models.download(asset)
                }
                .dsProminentButton()
            }
        case .downloading(let progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(width: 150)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("common.cancel")) {
                    models.cancelDownload(asset)
                }
                .dsGlassButton()
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("service.local.preparing"))
                    .foregroundStyle(.secondary)
            }
        case .ready(let size):
            HStack(spacing: 12) {
                Label(name.map { L("service.local.namedReady", $0, Self.bytes(size)) }
                      ?? L("service.local.ready", Self.bytes(size)),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(L("service.local.deleteModel")) {
                    confirmDelete = true
                }
                .dsGlassButton()
            }
        case .failed(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("service.local.download")) {
                    models.download(asset)
                }
                .dsProminentButton()
            }
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
