import SwiftUI
import AppKit
import LibraryCore

struct ItemListView: View {
    @ObservedObject var store: LibraryStore
    @ViewState<ListFocusRequest?> private var focusToRestore = nil
    @ViewState<String?> private var selectionToReveal = nil

    var body: some View {
        Group {
            if store.scope == .history { history }
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
                }
                Menu("整理到") {
                    Button("待整理") { store.organize(ids, into: nil) }
                    ForEach(store.snapshot.collections) { collection in
                        Button(collection.name) { store.organize(ids, into: collection.id) }
                    }
                }
                Divider()
                Button(role: .destructive) { store.requestDelete(ids) } label: {
                    Label(items.count == 1 ? "删除" : "删除 \(items.count) 项", systemImage: "trash")
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = store.items(for: ids).first else { return }
            if item.isEditable { store.edit(item) } else { store.open(item) }
        }
        .onDeleteCommand { store.requestDeleteSelection() }
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
            Picker("资料类型", selection: $store.kindFilter) {
                Text("全部").tag(Optional<ItemKind>.none)
                ForEach([ItemKind.document, .note, .thought, .image, .other], id: \.self) { kind in
                    Text(kind.label).tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
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
            if store.scope != .history, store.selection.count > 1 {
                bulkBar
                Divider()
            }
            statusBar
        }
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
                ForEach(store.snapshot.collections) { collection in
                    Button(collection.name) { store.organize(store.selection, into: collection.id) }
                }
            } label: {
                Label("整理到", systemImage: "folder")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button(role: .destructive) { store.requestDeleteSelection() } label: {
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
            Text("\(store.snapshot.items.count) 项").monospacedDigit()
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
                Text(item.text.isEmpty ? (item.extractionNote ?? "暂无正文") : excerpt)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(collection).lineLimit(1)
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
