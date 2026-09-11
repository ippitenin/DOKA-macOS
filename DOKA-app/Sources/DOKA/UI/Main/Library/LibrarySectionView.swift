import SwiftUI

/// Подтверждения секции «Библиотека» — один `.alert` на корне на все ветки:
/// несколько `.alert` на одной вью конфликтуют.
enum LibraryAlert {
    case deleteOne(FileTranscriptRecord)
    case deleteBatch(Set<UUID>)
}

/// Секция «Библиотека»: список ↔ запись с мгновенной сменой экрана (drill-in,
/// как «Расширенные»; NavigationStack в проекте не используется). Всё
/// состояние — в `LibraryModel.shared`: секция пересоздаётся при переключении.
struct LibrarySectionView: View {
    @ObservedObject private var model = LibraryModel.shared
    @State private var pendingAlert: LibraryAlert?

    var body: some View {
        // ZStack, а не Group: модификаторы Group раздаются детям, и алерт с
        // onDisappear срабатывали бы на каждой смене экрана.
        ZStack {
            if let document = model.openedDocument {
                TranscriptRecordView(document: document, layout: .full, onBack: { model.close() })
                    .id(document.recordID)
            } else {
                LibraryListView(onRequestDelete: { pendingAlert = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Звук останавливает сама запись в своём onDisappear (только свой):
        // безусловный stop() здесь гасил бы воспроизведение, уже запущенное в
        // новой секции, — onDisappear уходящей приходит после вставки новой.
        .alert(alertTitle, isPresented: alertPresented, presenting: pendingAlert) { alert in
            Button(L("library.delete.confirm"), role: .destructive) {
                switch alert {
                case .deleteOne(let record): model.delete([record.id])
                case .deleteBatch(let ids): model.delete(ids)
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { alert in
            switch alert {
            case .deleteOne(let record):
                Text(L("library.delete.messageNamed", record.displayTitle))
            case .deleteBatch(let ids):
                Text(L("library.delete.batch.message", ids.count))
            }
        }
    }

    private var alertTitle: String {
        switch pendingAlert {
        case .deleteBatch: return L("library.delete.batch.title")
        case .deleteOne, .none: return L("library.delete.title")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { pendingAlert != nil },
                set: { if !$0 { pendingAlert = nil } })
    }
}

/// Экран списка: поиск, группы по дате, строки, плашка мультивыбора.
struct LibraryListView: View {
    let onRequestDelete: (LibraryAlert) -> Void

    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var store = TranscriptHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool

    /// Высота зоны растворения карточек у верхней кромки ленты.
    private static let topFade: CGFloat = 28

    var body: some View {
        let items = model.filtered(store.records)
        VStack(alignment: .leading, spacing: 14) {
            header
            if showsRetentionNotice {
                retentionNotice
            }
            searchRow
            if items.isEmpty {
                emptyState
                    .padding(.bottom, 20)
            } else {
                scrollList(items)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if !model.selection.isEmpty { multiSelectBar(items) }
        }
        .animation(DS.Anim.control, value: model.selection.isEmpty)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 6) {
            Text(L("section.library"))
                .font(.title.bold())
            HelpBubble(text: retentionHelp)
            Spacer(minLength: 12)
            Button {
                WindowManager.shared.showMain(section: .transcribe)
            } label: {
                Label(L("library.transcribeFile"), systemImage: "waveform.badge.plus")
            }
            .dsGlassButton()
        }
    }

    /// Подсказка о сроке хранения — живая: следует `transcriptRetention`.
    private var retentionHelp: String {
        switch settings.transcriptRetention {
        case .forever:
            return L("library.help.forever")
        default:
            return L("library.help.hours", settings.transcriptRetention.title)
        }
    }

    /// Однократная плашка для тех, у кого «Недавние» жили 12 часов: теперь
    /// записи хранятся всегда. Кто выбрал срок сам, её не видит.
    private var showsRetentionNotice: Bool {
        !settings.libraryRetentionNoticeDismissed
            && !settings.isTranscriptRetentionExplicit
            && store.hasRecordsFromV1
    }

    private var retentionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "infinity")
                .foregroundStyle(DS.accent)
            Text(L("library.retentionNotice"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("library.retentionNotice.change")) {
                settings.libraryRetentionNoticeDismissed = true
                WindowManager.shared.showAdvancedSettings()
            }
            .dsGlassButton()
            Button {
                settings.libraryRetentionNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("library.retentionNotice.dismiss"))
        }
        .padding(DS.Spacing.cardPadding)
        .glassSurface()
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("library.search"), text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if model.isSearchingText {
                ProgressView().controlSize(.mini)
            }
            if !model.query.isEmpty {
                Button { model.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("library.search.clear"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassCapsule()
        // ⌘F — фокус в поиск. Невидимая кнопка с сочетанием: `onKeyPress` не
        // сработал бы, пока фокус не внутри секции.
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Лента

    /// Лента — паттерн истории: до нижней кромки окна, сверху карточки
    /// растворяются маской `topFade` (системный scrollEdgeEffectStyle тут не
    /// работает), индикатор выключен совсем.
    private func scrollList(_ items: [LibraryItem]) -> some View {
        let groups = LibraryGrouping.group(items, date: { $0.record.date },
                                           now: Date(), calendar: .current)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    // Заголовок не pinned: без подложки он налезал бы на стекло карточек.
                    Text(group.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, group.kind == groups.first?.kind ? 0 : 6)
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
            }
            .padding(.top, Self.topFade)
            .padding(.bottom, model.selection.isEmpty ? 20 : 76)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
                Color.black
            }
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        LibraryRow(
            item: item,
            query: model.appliedQuery,
            isSelected: model.selection.contains(item.id),
            isRenaming: model.renamingID == item.id,
            renameDraft: $model.renameDraft,
            onToggleSelect: { toggleSelection(item.id) },
            onOpen: { model.open(item.id) },
            onStartRename: { model.beginRename(item.record) },
            onCommitRename: { model.commitRename(ifRenaming: item.id) },
            onCancelRename: { model.cancelRename() },
            onDelete: { onRequestDelete(.deleteOne(item.record)) }
        )
    }

    private func toggleSelection(_ id: UUID) {
        if model.selection.contains(id) {
            model.selection.remove(id)
        } else {
            model.selection.insert(id)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.records.isEmpty {
                Image(systemName: "books.vertical")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                    .dsBreathe()
                Text(L("library.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L("library.transcribeFile")) {
                    WindowManager.shared.showMain(section: .transcribe)
                }
                .dsProminentButton()
            } else if model.isSearchingText {
                ProgressView().controlSize(.small)
                Text(L("library.searchingText"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(L("library.notFound"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .glassSurface()
    }

    // MARK: - Мультивыбор

    private func multiSelectBar(_ items: [LibraryItem]) -> some View {
        let visibleIDs = Set(items.map(\.id))
        let allVisibleSelected = !visibleIDs.isEmpty && visibleIDs.isSubset(of: model.selection)
        return HStack(spacing: 12) {
            Text(model.exportNote ?? L("library.multi.count", model.selection.count))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(allVisibleSelected ? L("library.multi.deselectAll") : L("library.multi.selectAll")) {
                if allVisibleSelected {
                    model.selection.subtract(visibleIDs)
                } else {
                    model.selection.formUnion(visibleIDs)
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(DS.accent)

            Menu {
                Button(L("library.export.combinedMd")) { model.exportCombined(markdown: true) }
                Button(L("library.export.combinedTxt")) { model.exportCombined(markdown: false) }
                Divider()
                Menu(L("library.export.toFolder")) {
                    ForEach(SaveFormat.folderExport) { format in
                        Button(format.title) { model.exportToFolder(format) }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassCapsule(interactive: true)
            .help(L("library.export"))

            Button {
                onRequestDelete(.deleteBatch(model.selection))
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassCapsule(interactive: true)
            .help(L("library.multi.delete"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(shadow: true)
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
