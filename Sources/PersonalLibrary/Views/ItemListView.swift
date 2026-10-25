import SwiftUI
import AppKit
import LibraryCore

struct ItemListView: View {
    @ObservedObject var store: LibraryStore
    @ViewState<ListFocusRequest?> private var focusToRestore = nil
    @ViewState<String?> private var selectionToReveal = nil
    @State private var showingFilters = false

    var body: some View {
        Group {
            if store.scope == .history { history }
            else if store.scope == .trash { trash }
            else { results }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    private var results: some View {
        List(selection: $store.selection) {
            ForEach(store.displayedItems) { item in
                ItemRow(item: item, collection: store.collectionName(item.collectionID),
                        excerpt: store.searchResults.presentations[item.id]?.excerpt ?? "")
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(ListFocusRequest.accessibilityID)
        .contextMenu(forSelectionType: String.self) { ids in
            let items = store.items(for: ids)
            if !items.isEmpty {
                let allFavorite = items.allSatisfy(\.favorite)
                Button(allFavorite ? "取消收藏" : "收藏") {
                    store.setFavorite(ids, value: !allFavorite)
                }
                if items.count == 1 {
                    let item = items[0]
                    if item.isEditable { Button("编辑") { store.edit(item) } }
                    else {
                        Button("打开文件") { store.open(item) }
                        Button("在 Finder 中显示") { store.reveal(item) }
                    }
                    Button("导出资料包…") { store.exportPackage(item) }
                }
                Menu("整理到") {
                    Button("待整理") { store.organize(ids, into: nil) }
                    collectionMenuButtons(store) { id in store.organize(ids, into: id) }
                }
                Button("标签…") { store.beginTagEditing(ids: ids) }
                Divider()
                Button(role: .destructive) { store.requestTrash(ids) } label: {
                    Label(items.count == 1 ? "删除" : "删除 \(items.count) 项", systemImage: "trash")
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = store.items(for: ids).first else { return }
            if item.isEditable { store.edit(item) } else { store.open(item) }
        }
        .onDeleteCommand { store.requestTrashSelection() }
        // Replace the native list and its selection actions together for a new result order.
        // AppKit's incremental insertion of thousands of automatic-height rows blocks the main thread.
        .background(ListLayoutCallback { window in
            restoreListFocus(in: window)
            revealKeyboardSelection(in: window)
        })
        .id(store.resultListID)
        .onReceive(store.$searchResults) { incoming in
            // @Published delivers before the old native result list is removed.
            if !store.searchResults.items.elementsEqual(incoming.items, by: { $0.id == $1.id }) {
                if let window = NSApp.keyWindow, let table = window.firstResponder as? NSTableView,
                   table.accessibilityIdentifier() == ListFocusRequest.accessibilityID {
                    focusToRestore = ListFocusRequest(listID: store.resultListID, window: window, previousList: table)
                } else {
                    focusToRestore = nil
                }
            }
        }
        .onChange(of: store.selectedID) { _, selectedID in
            // SwiftUI can scroll again after AppKit handles the arrow key. Reveal after layout.
            if let table = NSApp.keyWindow?.firstResponder as? NSTableView,
               table.accessibilityIdentifier() == ListFocusRequest.accessibilityID {
                selectionToReveal = selectedID
            } else {
                selectionToReveal = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, focusToRestore?.window === window {
                focusToRestore = nil
            }
            selectionToReveal = nil
        }
        .overlay {
            if store.displayedItems.isEmpty && !store.isSearching {
                ContentUnavailableView {
                    Label(store.query.isEmpty ? "还没有资料" : "没有搜索结果",
                          systemImage: store.query.isEmpty ? "tray" : "magnifyingglass")
                } description: {
                    Text(store.query.isEmpty ? "导入文件，或记录一个新想法。" : "试试其他关键词，或切换到全部资料。")
                } actions: {
                    if store.query.isEmpty {
                        Button("导入文件…") { store.chooseFiles() }
                            .disabled(!store.ready || store.isImporting)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Picker("资料类型", selection: $store.kindFilter) {
                    Text("全部").tag(Optional<ItemKind>.none)
                    ForEach([ItemKind.document, .note, .thought, .image, .other], id: \.self) { kind in
                        Text(kind.label).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Spacer(minLength: 0)
                sortMenu
                filterButton
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $store.listOptions.sortField) {
                ForEach(LibrarySortField.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            Divider()
            Button(store.listOptions.ascending ? "改为降序" : "改为升序") {
                store.listOptions.ascending.toggle()
            }
            if store.listOptions.sortField != .updated || store.listOptions.ascending {
                Divider()
                Button("恢复默认排序") {
                    store.listOptions.sortField = .updated
                    store.listOptions.ascending = false
                }
            }
        } label: {
            SwiftUI.Label("\(store.listOptions.sortField.label)\(store.listOptions.ascending ? " ↑" : " ↓")",
                          systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("排序：\(store.listOptions.sortField.label)，\(store.listOptions.ascending ? "升序" : "降序")")
    }

    private var filterButton: some View {
        Button {
            showingFilters.toggle()
        } label: {
            SwiftUI.Label(store.listOptions.hasFilters ? "筛选 \(store.listOptions.filterCount)" : "筛选",
                          systemImage: store.listOptions.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .popover(isPresented: $showingFilters, arrowEdge: .bottom) { filterPanel }
        .help("按日期、大小和内容筛选")
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("筛选").font(.headline)
            Toggle("按创建日期", isOn: dateRangeEnabled)
            if store.listOptions.startDate != nil || store.listOptions.endDate != nil {
                HStack(spacing: 12) {
                    DatePicker("从", selection: startDate, displayedComponents: .date)
                    DatePicker("到", selection: endDate, displayedComponents: .date)
                }.datePickerStyle(.compact)
            }
            Toggle("按大小", isOn: sizeRangeEnabled)
            if store.listOptions.minBytes != nil || store.listOptions.maxBytes != nil {
                HStack(spacing: 8) {
                    TextField("最小", text: minimumMegabytes).frame(width: 70)
                    Text("MB").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("最大", text: maximumMegabytes).frame(width: 70)
                    Text("MB").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("有正文", isOn: $store.listOptions.onlyWithBody)
            Toggle("有配图", isOn: $store.listOptions.onlyWithImages)
            Toggle("有外部链接", isOn: $store.listOptions.onlyWithLinks)
            Divider()
            HStack {
                Text(store.listOptions.hasFilters ? "\(store.displayedItems.count) 项符合条件" : "未设置筛选")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("清除筛选") { clearFilters() }
                    .disabled(!store.listOptions.hasFilters)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 320)
    }

    private var dateRangeEnabled: Binding<Bool> {
        Binding(get: { store.listOptions.startDate != nil || store.listOptions.endDate != nil }) { enabled in
            if enabled {
                let end = Date()
                store.listOptions.startDate = Calendar.current.date(byAdding: .month, value: -1, to: end)
                store.listOptions.endDate = endOfDay(end)
            } else {
                store.listOptions.startDate = nil
                store.listOptions.endDate = nil
            }
        }
    }

    private var startDate: Binding<Date> {
        Binding(get: { store.listOptions.startDate ?? Calendar.current.startOfDay(for: Date()) }) { date in
            store.listOptions.startDate = Calendar.current.startOfDay(for: date)
        }
    }

    private var endDate: Binding<Date> {
        Binding(get: { store.listOptions.endDate ?? Date() }) { date in
            store.listOptions.endDate = endOfDay(date)
        }
    }

    private var sizeRangeEnabled: Binding<Bool> {
        Binding(get: { store.listOptions.minBytes != nil || store.listOptions.maxBytes != nil }) { enabled in
            if enabled {
                store.listOptions.minBytes = nil
                store.listOptions.maxBytes = Int64(10 * 1024 * 1024)
            } else {
                store.listOptions.minBytes = nil
                store.listOptions.maxBytes = nil
            }
        }
    }

    private var minimumMegabytes: Binding<String> {
        Binding(get: { store.listOptions.minBytes.map(megabytes) ?? "" }) { text in
            store.listOptions.minBytes = bytes(text)
        }
    }

    private var maximumMegabytes: Binding<String> {
        Binding(get: { store.listOptions.maxBytes.map(megabytes) ?? "" }) { text in
            store.listOptions.maxBytes = bytes(text)
        }
    }

    private func megabytes(_ value: Int64) -> String {
        let mb = Double(value) / 1_048_576
        return mb == mb.rounded() ? String(Int(mb)) : String(format: "%.1f", mb)
    }

    private func bytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value >= 0 else { return nil }
        return Int64(value * 1_048_576)
    }

    private func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? date
    }

    private func clearFilters() {
        let sort = store.listOptions.sortField
        let ascending = store.listOptions.ascending
        store.listOptions = LibraryListOptions()
        store.listOptions.sortField = sort
        store.listOptions.ascending = ascending
    }

    private func restoreListFocus(in window: NSWindow) {
        guard let request = focusToRestore else { return }
        guard request.listID == store.resultListID, let expectedWindow = request.window else {
            focusToRestore = nil
            return
        }
        guard window === expectedWindow else { return }
        guard NSApp.keyWindow === window else { focusToRestore = nil; return }
        guard let content = window.contentView else { return }
        let tables = ListFocusRequest.tables(in: content).filter {
            $0 !== request.previousList && $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                && !$0.visibleRect.isEmpty && $0.numberOfRows == store.displayedItems.count
        }
        guard tables.count == 1, let table = tables.first else { return }
        let responder = window.firstResponder
        let indexes = IndexSet(store.displayedItems.enumerated().compactMap {
            store.selection.contains($0.element.id) ? $0.offset : nil
        })
        guard responder === window || responder === request.previousList || responder === table,
              !indexes.isEmpty else {
            focusToRestore = nil
            return
        }
        var estimatedHeight: CGFloat?
        if table.usesAutomaticRowHeights, table.rowSizeStyle == .custom {
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0,
                  let row = table.rowView(atRow: visible.location, makeIfNecessary: true) else { return }
            let height = row.frame.height - table.intercellSpacing.height
            guard height > 0 else { return }
            estimatedHeight = height
        }
        // Consume before native actions, which can cause another layout callback.
        focusToRestore = nil
        if let estimatedHeight {
            // With automatic row heights this estimates unloaded rows; actual heights stay automatic.
            // Refresh the default estimates already cached by the newly installed list.
            table.rowHeight = estimatedHeight
            table.reloadData()
        }
        guard table.numberOfRows == store.displayedItems.count, indexes.last! < table.numberOfRows,
              window.makeFirstResponder(table) else { return }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        guard let index = indexes.first else { return }
        table.scrollRowToVisible(index)
        let rowRect = table.rect(ofRow: index)
        let margin = max(0, (table.visibleRect.height - rowRect.height) / 2)
        _ = table.scrollToVisible(rowRect.insetBy(dx: 0, dy: -margin))
    }

    private func revealKeyboardSelection(in window: NSWindow) {
        guard let id = selectionToReveal else { return }
        guard NSApp.keyWindow === window,
              let table = window.firstResponder as? NSTableView,
              table.accessibilityIdentifier() == ListFocusRequest.accessibilityID,
              id == store.selectedID,
              let index = store.displayedItems.firstIndex(where: { $0.id == id }),
              table.numberOfRows == store.displayedItems.count,
              table.selectedRow == index else { selectionToReveal = nil; return }
        selectionToReveal = nil
        table.scrollRowToVisible(index)
    }

    /// Trashed rows keep their copies, so this list only ever restores or destroys.
    private var trash: some View {
        List(selection: $store.selection) {
            ForEach(store.displayedItems) { item in
                ItemRow(item: item, collection: store.collectionName(item.collectionID), excerpt: "")
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button("恢复") { store.restoreFromTrash(ids) }
                Divider()
                Button(role: .destructive) { store.requestPermanentDelete(ids) } label: {
                    Label(ids.count == 1 ? "彻底删除" : "彻底删除 \(ids.count) 项", systemImage: "trash.slash")
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = store.items(for: ids).first else { return }
            store.open(item)
        }
        .onDeleteCommand { store.requestPermanentDelete(store.selection) }
        .overlay {
            if store.displayedItems.isEmpty {
                ContentUnavailableView("回收站是空的", systemImage: "trash",
                                       description: Text("删除的资料会在这里保留 \(LibraryRetention.trashDays) 天，之后自动清理。"))
            }
        }
    }

    private var history: some View {
        List(store.snapshot.activities) { activity in
            Label {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.message).font(.body)
                    Text(activity.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                .padding(.vertical, 7)
        }
        .listStyle(.inset)
        .overlay {
            if store.snapshot.activities.isEmpty {
                ContentUnavailableView("暂无整理记录", systemImage: "clock.arrow.circlepath",
                                       description: Text("每一次导入与整理，都会留下一条记录。"))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if store.scope == .trash, !store.selection.isEmpty {
                trashBar
                Divider()
            } else if store.scope != .history, store.selection.count > 1 {
                bulkBar
                Divider()
            }
            if store.canUndoTrash {
                undoBar
                Divider()
            }
            statusBar
        }
    }

    private var trashBar: some View {
        HStack(spacing: 14) {
            Text("已选择 \(store.selection.count) 项")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { store.restoreFromTrash(store.selection) } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { store.requestPermanentDelete(store.selection) } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        }
        .buttonStyle(.borderless)
        .disabled(store.isDeleting || store.isBatchUpdating)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    /// The trash keeps a session-scoped undo until the next destructive action.
    private var undoBar: some View {
        HStack(spacing: 10) {
            Label("已移到回收站", systemImage: "trash").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("撤销") { store.undoTrash() }
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销删除 · ⌘Z")
            Button("关闭") { store.dismissUndoTrash() }
                .buttonStyle(.borderless)
        }
        .disabled(store.isDeleting)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var bulkBar: some View {
        let allFavorite = !store.selection.isEmpty && store.items(for: store.selection).allSatisfy { $0.favorite }
        return HStack(spacing: 14) {
            Text("已选择 \(store.selection.count) 项")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { store.setFavorite(store.selection, value: !allFavorite) } label: {
                Label(allFavorite ? "取消收藏" : "收藏", systemImage: allFavorite ? "star.slash" : "star")
            }
            Menu {
                Button("待整理") { store.organize(store.selection, into: nil) }
                collectionMenuButtons(store) { id in store.organize(store.selection, into: id) }
            } label: {
                Label("整理到", systemImage: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button(role: .destructive) { store.requestTrashSelection() } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .buttonStyle(.borderless)
        .disabled(store.isBatchUpdating || store.isDeleting)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if store.isImporting || store.isSearching || store.isDeleting { ProgressView().controlSize(.mini) }
            else { Image(systemName: store.ready ? "lock.shield" : "hourglass") }
            Text(store.isDeleting ? "正在删除…" : (store.isSearching ? "正在搜索…" : store.status)).lineLimit(1)
            Spacer(minLength: 0)
            if store.scope == .trash {
                Button("清空回收站") { store.requestEmptyTrash() }
                    .buttonStyle(.borderless)
                    .disabled(store.trashedCount == 0 || store.isDeleting)
            }
            Text("\(store.scope == .trash ? store.trashedCount : store.snapshot.items.count) 项").monospacedDigit()
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct ItemRow: View {
    let item: LibraryItem
    let collection: String
    let excerpt: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileBadge(item: item)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.favorite { Image(systemName: "star.fill").font(.caption2) }
                }
                Text(excerpt.isEmpty ? (item.preview.isEmpty ? (item.extractionNote ?? "暂无正文") : item.preview) : excerpt)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(collection).lineLimit(1)
                    if !item.tags.isEmpty {
                        Text(item.tags.map { "#" + $0 }.joined(separator: "  "))
                            .lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(item.updatedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                }.font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

private final class ListFocusRequest {
    static let accessibilityID = "library-results"
    let listID: UUID
    weak var window: NSWindow?
    weak var previousList: NSTableView?

    init(listID: UUID, window: NSWindow, previousList: NSTableView) {
        self.listID = listID
        self.window = window
        self.previousList = previousList
    }

    static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView, table.accessibilityIdentifier() == accessibilityID { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
}

// Observe the replacement list's own attachment/layout; window updates need a user event.
private struct ListLayoutCallback: NSViewRepresentable {
    var onLayout: (NSWindow) -> Void

    func makeNSView(context: Context) -> LayoutView { LayoutView() }
    func updateNSView(_ view: LayoutView, context: Context) {
        view.onLayout = onLayout
        view.scheduleCallback()
    }
    static func dismantleNSView(_ view: LayoutView, coordinator: ()) { view.onLayout = nil }

    final class LayoutView: NSView {
        var onLayout: ((NSWindow) -> Void)?
        private var callbackScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleCallback() }
        override func layout() { super.layout(); scheduleCallback() }

        func scheduleCallback() {
            guard !callbackScheduled, window != nil else { return }
            callbackScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.callbackScheduled = false
                if let window = self.window { self.onLayout?(window) }
            }
        }
    }
}
