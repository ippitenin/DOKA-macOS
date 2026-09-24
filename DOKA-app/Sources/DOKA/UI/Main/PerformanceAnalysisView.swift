import SwiftUI

/// Модальный экран «Анализ производительности» по выбранным записям истории:
/// сводные плитки, сведения о системе и разбивка по моделям/провайдерам с метрикой
/// «во сколько раз быстрее реального времени». Считается из `PerformanceMetrics`.
struct PerformanceAnalysisView: View {
    let records: [TranscriptionRecord]
    @Environment(\.dismiss) private var dismiss

    private var metrics: PerformanceMetrics { PerformanceMetrics(records: records) }
    private let system = SystemInfo.current()

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        topTiles
                        systemSection
                        modelsSection
                        if metrics.byProvider.count > 1 { providersSection }
                    }
                    .padding(24)
                }
            }
        }
        // Ниже окна (640): шит встаёт по центру с воздухом сверху и снизу,
        // контент и так прокручивается.
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 500)
    }

    private var header: some View {
        HStack {
            Text(L("perf.title")).font(.title2.bold())
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // Системное синее кольцо фокуса выбивается из дизайна: при полном
            // доступе с клавиатуры фокус вставал на крестик (в шитах — сразу при открытии).
            .focusEffectDisabled()
            .help(L("common.close"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var topTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            PerfTile(symbol: "doc.text.fill", value: "\(metrics.totalTranscripts)",
                     caption: L("perf.tile.total"), color: DS.Aurora.indigo)
            PerfTile(symbol: "waveform.path.ecg", value: "\(metrics.analyzableCount)",
                     caption: L("perf.tile.analyzable"), color: DS.accent)
            PerfTile(symbol: "text.word.spacing", value: groupedInt(metrics.totalWords),
                     caption: L("perf.tile.words"), color: DS.coral)
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("perf.system.title")).font(.headline)
            VStack(spacing: 0) {
                infoRow(L("perf.system.device"), system.device)
                CardDivider()
                infoRow(L("perf.system.processor"), system.processor)
                CardDivider()
                infoRow(L("perf.system.memory"), system.memory)
            }
            .glassSurface()
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("perf.models.title")).font(.headline)
            if metrics.byModel.isEmpty {
                Text(L("perf.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .glassSurface()
            } else {
                ForEach(metrics.byModel) { group in
                    PerfGroupCard(group: group)
                }
            }
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("perf.providers.title")).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(metrics.byProvider) { group in
                    PerfProviderChip(group: group)
                }
            }
        }
    }

    private func groupedInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Плитка-сводка

private struct PerfTile: View {
    let symbol: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(color)
            Text(value)
                .font(.title.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .glassSurface()
    }
}

// MARK: - Карточка модели (геро «N× быстрее»)

private struct PerfGroupCard: View {
    let group: PerformanceMetrics.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.name).font(.headline)
                Spacer()
                Text(L("perf.group.transcripts", group.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Не `CardDivider`: у него свой боковой отступ под строки без
            // паддинга, а карточка уже с `cardPadding` — линия выходила уже
            // текста. Здесь — во всю ширину содержимого, вид тот же.
            Divider().opacity(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatMultiplier(group.fasterThanRealtime))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(DS.accent)
                    .monospacedDigit()
                Text("×")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(DS.accent)
                Text(L("perf.group.faster"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            HStack(spacing: 28) {
                stat(L("perf.group.avgAudio"), formatStatDuration(group.avgAudio))
                stat(L("perf.group.avgProcess"),
                     String(format: "%.2f\u{00A0}\(L("history.unit.seconds"))", group.avgProcess))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.cardPadding)
        .glassSurface()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }
}

// MARK: - Чип провайдера

private struct PerfProviderChip: View {
    let group: PerformanceMetrics.Group

    private var title: String {
        TranscriptionProvider(rawValue: group.name)?.title ?? group.name
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(L("perf.group.transcripts", group.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(formatMultiplier(group.fasterThanRealtime))×")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(DS.accent)
        }
        .padding(DS.Spacing.cardPadding)
        .glassSurface()
    }
}

/// Множитель «2,6» / «2.6» — десятичный разделитель по языку интерфейса.
private func formatMultiplier(_ value: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 1
    f.maximumFractionDigits = 1
    f.locale = .current
    return f.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
}
