import AppKit
import SwiftUI

/// Окно «Тренировка» (эксперимент «Губы»): фраза крупно, под ней живое
/// зеркало рта, управление с клавиатуры — пробел (начать / стоп), → (пропустить),
/// R (переписать прошлую), Esc (выбросить фразу / закрыть окно). Логика —
/// в `LipTrainingController`; окно им только управляет.
struct LipTrainingView: View {
    @ObservedObject private var controller = LipTrainingController.shared
    @ObservedObject private var capture = LipCapture.shared
    @ObservedObject private var store = LipDataStore.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    static let width: CGFloat = 520
    static let padding: CGFloat = 24
    /// На всю ширину контента — по одной линии с карточкой фразы и кнопками.
    /// Пропорции — как у зеркала панели записи: кадр рта под ту же камеру.
    static let mirrorSize: CGSize = {
        let width = Self.width - 2 * Self.padding
        let aspect = LipMirrorGeometry.videoSize.height / LipMirrorGeometry.videoSize.width
        return CGSize(width: width, height: (width * aspect).rounded())
    }()

    var body: some View {
        VStack(spacing: 16) {
            header
            phraseCard
            mirror
            status
            if !permissions.cameraAuthorized { cameraPermissionRow }
            controls
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background(AppBackground().ignoresSafeArea())
        // Клавиши — на корне, а не скрытыми кнопками с `keyboardShortcut`:
        // фокус держит сам корень (как у записи библиотеки).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            controller.toggle()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            controller.skip()
            return .handled
        }
        .onKeyPress(.escape) {
            if controller.phase.isActive {
                controller.cancel()
            } else {
                WindowManager.shared.closeTraining()
            }
            return .handled
        }
        // R и «К» — одна клавиша в английской и русской раскладке.
        .onKeyPress(characters: CharacterSet(charactersIn: "rRкК")) { _ in
            controller.rewritePrevious()
            return .handled
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Фокус — со следующего цикла: иначе клавиши молчат до первого клика.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("training.mode"), systemImage: "mouth")
                .font(.headline)
            Text(L("training.instruction"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Фраза

    private var phraseCard: some View {
        VStack(spacing: 10) {
            Text(phraseText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(controller.current == nil ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 88)
            // Нижняя строка карточки: источник фразы слева, счётчик справа —
            // оба прижаты к краям карточки, а не висят в шапке.
            HStack {
                if let origin = controller.current?.origin {
                    Text(origin.title)
                }
                Spacer(minLength: 12)
                Text(L("training.counts", controller.sessionSaved, store.summary.silent))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .glassSurface()
    }

    private var phraseText: String {
        if let phrase = controller.current { return phrase.text }
        return controller.isLoading ? L("training.loading") : L("training.exhausted")
    }

    // MARK: - Зеркало

    private var mirror: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            Color.black
            // Вью зеркала живёт только во время фразы: ящик кадров отдаёт
            // их последнему подписчику, и вечная подписка спорила бы с
            // зеркалом панели записи, если посреди тренировки начнут диктовать.
            if controller.phase.isActive {
                LipMirrorVideoView(size: Self.mirrorSize, reduceMotion: reduceMotion)
            }
            if let caption = mirrorCaption {
                Color.black.opacity(controller.phase.isActive ? 0.55 : 0)
                VStack(spacing: 8) {
                    if !controller.phase.isActive {
                        Image(systemName: "camera")
                            .font(.title2)
                    }
                    Text(caption)
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(DS.Lips.caption)
            }
        }
        .frame(width: Self.mirrorSize.width, height: Self.mirrorSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Lips.rim, lineWidth: 0.5))
        .animation(reduceMotion ? nil : DS.Anim.control, value: capture.phase)
    }

    private var mirrorCaption: String? {
        guard controller.phase.isActive else { return L("training.mirror.idle") }
        switch capture.phase {
        case .face: return nil
        case .warming, .idle: return L("lips.mirror.warming")
        case .noLips: return L("lips.mirror.noLips")
        case .unavailable: return L("lips.mirror.unavailable")
        }
    }

    // MARK: - Состояние

    private var status: some View {
        VStack(spacing: 6) {
            statusLine
            if let last = controller.last {
                Text(lastText(last))
                    .font(.caption)
                    .foregroundStyle(lastIsProblem(last) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let notice = controller.notice {
            Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        } else {
            switch controller.phase {
            case .idle:
                if controller.current != nil {
                    HStack(spacing: 6) {
                        KeyHint(L("training.key.space"))
                        Text(L("training.status.idle"))
                    }
                    .foregroundStyle(.secondary)
                }
            case .warming:
                Text(L("training.status.warming"))
                    .foregroundStyle(.secondary)
            case .recording(let since):
                TimelineView(.periodic(from: since, by: 0.5)) { context in
                    HStack(spacing: 8) {
                        Circle().fill(DS.RecorderTone.recording).frame(width: 9, height: 9)
                        Text(L("training.status.recording")).fontWeight(.semibold)
                        Text(clockMMSS(context.date.timeIntervalSince(since)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        KeyHint(L("training.key.space"))
                        Text(L("training.status.stopHint"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func lastText(_ last: LipTrainingSession.Last) -> String {
        switch last.result {
        case .held: return L("training.last.held")
        case .processing: return L("training.last.processing")
        case .saved: return L("training.last.saved")
        case .rejected(let reason):
            return L("training.last.rejected", last.phrase.text, reason?.title ?? L("training.last.lost"))
        }
    }

    private func lastIsProblem(_ last: LipTrainingSession.Last) -> Bool {
        if case .rejected = last.result { return true }
        return false
    }

    // MARK: - Разрешение и кнопки

    private var cameraPermissionRow: some View {
        HStack(spacing: 10) {
            Text(LipTrainingController.Notice.cameraPermission.text)
                .foregroundStyle(.secondary)
            CameraAccessButton()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { controller.skip() } label: {
                HStack(spacing: 6) {
                    Text(L("training.skip"))
                    KeyHint("→")
                }
            }
            .dsGlassButton()
            .disabled(controller.phase.isActive || controller.current == nil)

            Button { controller.rewritePrevious() } label: {
                HStack(spacing: 6) {
                    Text(L("training.rewrite"))
                    KeyHint("R")
                }
            }
            .dsGlassButton()
            .disabled(!controller.canRewrite)

            Spacer(minLength: 0)

            Button { controller.toggle() } label: {
                Text(controller.phase.isActive ? L("training.stop") : L("training.start"))
                    .frame(minWidth: 70)
            }
            .dsProminentButton()
            .disabled(controller.current == nil || !permissions.cameraAuthorized)
        }
        // Кнопки фокус не забирают: пробел должен доходить до корня окна.
        .focusable(false)
    }
}

/// Подсказка клавиши — маленький бэйдж рядом с подписью.
private struct KeyHint: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
