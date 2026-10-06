import SwiftUI

// «Угадать имена»: кнопка в полосе спикеров и плашка с предложениями под ней.
// Предложения применяются только по кнопке — через те же правки документа,
// что и ручное переименование и слияние (`TranscriptDocument`).

/// Кнопка в полосе спикеров; во время работы — «Ищу имена…» и «Отмена».
struct SpeakerSuggestButton: View {
    let document: TranscriptDocument
    @ObservedObject private var controller = SpeakerSuggestionController.shared
    // Доступность зависит от анализа и наличия модели: без подписки кнопка
    // не узнала бы, что анализ закончился или модель докачалась.
    @ObservedObject private var analysis = AnalysisController.shared
    @ObservedObject private var models = LocalModelStore.shared

    var body: some View {
        if case .running = controller.phase(for: document.recordID) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("speakers.suggest.running"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("common.cancel")) { controller.cancel() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DS.accent)
            }
            .padding(.top, 4)
        } else {
            let availability = controller.availability(for: document.recordID)
            Button {
                if availability == .modelMissing {
                    controller.requestModel(for: document.recordID)
                } else {
                    controller.start(document: document)
                }
            } label: {
                Label(L("speakers.suggest.button"), systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(DS.accent)
            .disabled(availability != .ok && availability != .modelMissing)
            .help(hint(availability))
            .padding(.top, 4)
        }
    }

    private func hint(_ availability: SpeakerSuggestionController.Availability) -> String {
        switch availability {
        case .ok, .modelMissing: return L("speakers.suggest.help")
        case .busyAnalysis: return L("speakers.suggest.busy.analysis")
        case .busyTranscribing: return L("analysis.busy.transcribing")
        case .busyOtherRecord: return L("speakers.suggest.busy.other")
        case .frozen: return L("transcribe.error.restartRequired")
        }
    }
}

/// Плашка с предложениями под полосой спикеров.
struct SpeakerSuggestionsPanel: View {
    let document: TranscriptDocument
    let roster: [SpeakerInfo]
    @ObservedObject private var controller = SpeakerSuggestionController.shared
    @ObservedObject private var models = LocalModelStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .modelNeeded:
                    modelNeeded
                case .ready(let suggestions, let covered):
                    ready(suggestions, covered: covered)
                case .failed(let message):
                    header(L("speakers.suggest.failed", message), showsApplyAll: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .fill(DS.accent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .strokeBorder(DS.accent.opacity(0.25), lineWidth: 1)
            )
        }
    }

    /// Что показывать; nil — плашки нет вовсе (и её рамки тоже).
    private enum PanelState {
        case modelNeeded
        case ready(SpeakerNameSuggester.Suggestions, covered: Double?)
        case failed(String)
    }

    private var state: PanelState? {
        let recordID = document.recordID
        if controller.modelRequestRecordID == recordID && !models.isDownloaded(.llm) {
            return .modelNeeded
        }
        switch controller.phase(for: recordID) {
        case .ready(_, let suggestions, let covered):
            return .ready(suggestions, covered: covered)
        case .failed(_, let message):
            return .failed(message)
        case .running, .idle, nil:
            return nil
        }
    }

    // MARK: - Состояния

    private var modelNeeded: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(L("speakers.suggest.modelNeeded"), showsApplyAll: false)
            LocalAssetStatusView(asset: .llm, name: LLMModelSpec.current.displayName)
        }
    }

    @ViewBuilder
    private func ready(_ suggestions: SpeakerNameSuggester.Suggestions, covered: Double?) -> some View {
        let names = suggestions.names.filter { suggestion in
            // Спикера успели переименовать вручную или влить в другого.
            roster.first { $0.id == suggestion.speakerID }.map { !$0.hasCustomName } ?? false
        }
        let merges = suggestions.merges.filter { merge in
            roster.contains { $0.id == merge.sourceID } && roster.contains { $0.id == merge.targetID }
        }
        if names.isEmpty && merges.isEmpty {
            header(L("speakers.suggest.none"), showsApplyAll: false)
        } else {
            header(L("speakers.suggest.title"), showsApplyAll: names.count + merges.count > 1) {
                names.forEach(apply)
                merges.forEach(apply)
            }
            ForEach(names) { nameRow($0) }
            ForEach(merges) { mergeRow($0) }
        }
        if let covered {
            Text(L("speakers.suggest.covered", max(1, Int(covered / 60))))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ title: String, showsApplyAll: Bool,
                        applyAll: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showsApplyAll {
                Button(L("speakers.suggest.applyAll"), action: applyAll)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.accent)
            }
            Button {
                controller.dismiss(recordID: document.recordID)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("speakers.suggest.close"))
        }
    }

    private func nameRow(_ suggestion: SpeakerNameSuggester.NameSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let info = roster.first(where: { $0.id == suggestion.speakerID }) {
                SpeakerChipLabel(info: info, showsCount: false)
            }
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(suggestion.name)
                .font(.callout.weight(.semibold))
            evidence(quote: suggestion.quote, time: suggestion.time)
            Spacer(minLength: 8)
            decision(apply: L("speakers.suggest.apply")) { apply(suggestion) } dismiss: {
                controller.resolve(suggestion.id, recordID: document.recordID)
            }
        }
    }

    /// Цитата-доказательство и кликабельный тайм-код.
    @ViewBuilder
    private func evidence(quote: String?, time: Double?) -> some View {
        if quote != nil || time != nil {
            HStack(spacing: 4) {
                if let quote {
                    Text(L("speakers.suggest.quote", quote))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let time {
                    Button(TranscriptFormatter.clock(time)) {
                        if let url = URL(string: "doka-seek:\(time)") { openURL(url) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func mergeRow(_ merge: SpeakerNameSuggester.MergeSuggestion) -> some View {
        let source = roster.first { $0.id == merge.sourceID }
        let target = roster.first { $0.id == merge.targetID }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let source { SpeakerChipLabel(info: source, showsCount: false) }
            Text(L("speakers.suggest.and"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let target { SpeakerChipLabel(info: target, showsCount: false) }
            Text(L("speakers.suggest.samePerson"))
                .font(.callout)
            evidence(quote: merge.quote, time: merge.time)
            Spacer(minLength: 8)
            decision(apply: L("speakers.suggest.merge")) { apply(merge) } dismiss: {
                controller.resolve(merge.id, recordID: document.recordID)
            }
        }
    }

    private func decision(apply title: String, apply: @escaping () -> Void,
                          dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(title, action: apply)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.accent)
            Button(L("speakers.suggest.dismiss"), action: dismiss)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!document.canEdit)
    }

    // MARK: - Применение

    private func apply(_ suggestion: SpeakerNameSuggester.NameSuggestion) {
        document.renameSpeaker(suggestion.speakerID, to: suggestion.name)
        controller.resolve(suggestion.id, recordID: document.recordID)
    }

    private func apply(_ merge: SpeakerNameSuggester.MergeSuggestion) {
        document.mergeSpeaker(merge.sourceID, into: merge.targetID)
        controller.resolve(merge.id, recordID: document.recordID)
    }
}
