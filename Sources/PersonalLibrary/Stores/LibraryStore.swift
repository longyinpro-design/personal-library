import AppKit
import Foundation
import LibraryCore
import SwiftUI
import UniformTypeIdentifiers

enum LibraryScope: Hashable, Sendable {
    case recent, all, inbox, notes, thoughts, favorites, history, trash, collection(String), tag(String)
    var title: String {
        switch self {
        case .recent: return "最近添加"
        case .all: return "全部资料"
        case .inbox: return "待整理"
        case .notes: return "我的笔记"
        case .thoughts: return "随笔"
        case .favorites: return "已收藏"
        case .history: return "整理记录"
        case .trash: return "回收站"
        case .collection: return "目录"
        case .tag: return "标签"
        }
    }
}

@MainActor
final class NoteDraft: Identifiable, ObservableObject {
    let id = UUID()
    let itemID: String?
    @Published var title: String
    @Published var body: String
    let kind: ItemKind
    private let initialTitle: String
    private let initialBody: String
    var hasChanges: Bool { title != initialTitle || body != initialBody }

    init(itemID: String? = nil, title: String = "", body: String = "", kind: ItemKind = .note) {
        self.itemID = itemID; self.title = title; self.body = body; self.kind = kind
        initialTitle = title; initialBody = body
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var snapshot = LibrarySnapshot() { didSet { if !suppressSearch { scheduleSearch() } } }
    @Published var scope: LibraryScope = .all { didSet { if oldValue != scope { scheduleSearch() } } }
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            if scope == .history && !query.isEmpty { navigate(.all) }
            scheduleSearch(debounce: true)
        }
    }
    @Published var kindFilter: ItemKind? { didSet { if oldValue != kindFilter { scheduleSearch() } } }
    @Published var listOptions = LibraryListOptions() { didSet { if oldValue != listOptions { scheduleSearch() } } }
    @Published private(set) var searchResults = LibrarySearchResults()
    // Changes before publishing results, and only when membership/order changes.
    private(set) var resultListID = UUID()
    @Published private(set) var isSearching = false
    @Published var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            if let pending = pendingReading, selectedID != pending.itemID { pendingReading = nil }
        }
    }
    @Published var pendingDeletion: Set<String> = []
    /// True when the pending confirmation will destroy copies instead of trashing them.
    private(set) var pendingDeletionIsPermanent = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isBatchUpdating = false
    /// Items trashed in this session, offered back through the undo banner.
    @Published private(set) var undoableTrash: Set<String> = []
    @Published var confirmEmptyTrash = false
    var selectedID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set {
            let next = newValue.map { Set([$0]) } ?? []
            if selection != next { selection = next }
        }
    }
    @Published private(set) var readingRequest: ReadingRequest?
    @Published private(set) var backHistory: [ReadingLocation] = []
    @Published private(set) var forwardHistory: [ReadingLocation] = []
    @Published var linkedFilePreview: LinkedFilePreview?
    private var pendingReading: ReadingRequest?
    @Published var draft: NoteDraft?
    @Published var errorMessage: String?
    @Published var status = "正在打开本地资料库…"
    @Published var isImporting = false
    /// Set when an import found files whose bytes already exist in the library.
    @Published var pendingImport: LibraryRepository.ImportPreview?
    @Published var isSavingNote = false
    @Published var ready = false
    @Published var focusSearch = false
    @Published var showNewCollection = false
    @Published private(set) var backups: [LibraryBackup] = []
    @Published private(set) var isBackingUp = false
    @Published private(set) var hasPendingRestore = false
    @Published private(set) var pendingRestoreName = ""
    let root: URL
    private var repository: LibraryRepository?
    private var bodyCache: [String: String] = [:]
    private var readingAnchors: [String: ReadingAnchor] = [:]
    private var suppressSearch = false
    @Published private(set) var bodyLoadingIDs: Set<String> = []
    private var searchGeneration = 0
    private(set) var searchTask: Task<Void, Never>?

    init(root: URL? = nil) {
        if let root { self.root = root; return }
        let arguments = ProcessInfo.processInfo.arguments
        let pathIndex = arguments.firstIndex(of: "--library-path")
        let commandLineRoot = pathIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        if let override = commandLineRoot ?? ProcessInfo.processInfo.environment["PERSONAL_LIBRARY_HOME"], !override.isEmpty {
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PersonalLibrary", isDirectory: true)
        }
    }

    var scopeTitle: String {
        if case .collection(let id) = scope { return collectionName(id) }
        if case .tag(let name) = scope { return "#" + name }
        return scope.title
    }

    var displayedItems: [LibraryItem] { searchResults.items }
    var trashedItems: [LibraryItem] { snapshot.trashed }
    var trashedCount: Int { snapshot.trashed.count }
    /// Undo stays available until another destructive action or a scope change.
    var canUndoTrash: Bool { !undoableTrash.isEmpty && !isDeleting && draft == nil }

    /// One cancellable request per input. Metadata searches stay on the repository
    /// actor; only the test-only in-memory fallback builds a detached worker.
    private func scheduleSearch(debounce: Bool = false) {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let items = snapshot.items
        let trashed = snapshot.trashed
        let scope = scope
        let kind = kindFilter
        let query = query
        let repository = repository
        let options = listOptions
        let filter = searchFilter(for: scope, kind: kind)
        isSearching = scope != .history && scope != .trash
        searchTask = Task { [weak self] in
            do {
                if debounce && !query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                try Task.checkCancellation()
                var results: LibrarySearchResults
                if scope == .history {
                    results = LibrarySearchResults(query: query)
                } else if scope == .trash {
                    results = Self.trashResults(trashed, query: query, kind: kind)
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results = try Self.metadataResults(items: items, scope: scope, kind: kind, query: query)
                } else if let repository {
                    results = try await repository.search(query: query, filter: filter)
                } else {
                    let worker = Task.detached(priority: .userInitiated) {
                        let candidates = Self.scopedItems(items, scope: scope, kind: kind)
                        return try LibrarySearch.search(candidates, query: query)
                    }
                    results = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                }
                results = Self.applying(options, to: results, hasQuery: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                if !self.searchResults.items.elementsEqual(results.items, by: { $0.id == $1.id }) {
                    self.resultListID = UUID()
                }
                self.searchResults = results
                self.isSearching = false
                if let pending = self.pendingReading, results.items.contains(where: { $0.id == pending.itemID }) {
                    self.selectedID = pending.itemID
                    self.readingRequest = pending
                    self.pendingReading = nil
                }
                self.selectVisibleItem()
            } catch is CancellationError {
                // A newer query, scope, filter, or snapshot owns the next visible result.
            } catch {
                guard let self, self.searchGeneration == generation else { return }
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func searchFilter(for scope: LibraryScope, kind: ItemKind?) -> LibrarySearchFilter {
        var filter = LibrarySearchFilter()
        switch scope {
        case .all, .history: break
        case .recent: filter.recentLimit = 50
        case .inbox: filter.inboxOnly = true
        case .notes: filter.kind = .note
        case .thoughts: filter.kind = .thought
        case .favorites: filter.favoritesOnly = true
        case .collection(let id): filter.collectionID = id
        case .tag(let name): filter.tagName = name
        case .trash: break
        }
        if let kind { filter.kind = kind }
        return filter
    }

    nonisolated private static func scopedItems(_ items: [LibraryItem], scope: LibraryScope, kind: ItemKind?) -> [LibraryItem] {
        var candidates = items.filter { item in
            switch scope {
            case .all, .recent: return true
            case .inbox: return item.collectionID == nil
            case .notes: return item.kind == .note
            case .thoughts: return item.kind == .thought
            case .favorites: return item.favorite
            case .collection(let id): return item.collectionID == id
            case .tag(let name): return item.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case .history, .trash: return false
            }
        }
        if scope == .recent { candidates = Array(candidates.sorted { $0.createdAt > $1.createdAt }.prefix(50)) }
        if let kind { candidates = candidates.filter { $0.kind == kind } }
        return candidates
    }

    nonisolated private static func metadataResults(items: [LibraryItem], scope: LibraryScope, kind: ItemKind?, query: String) throws -> LibrarySearchResults {
        try LibrarySearch.search(scopedItems(items, scope: scope, kind: kind), query: query)
    }

    /// Trash rows carry only a preview, so the search matches titles and previews
    /// instead of the full body the reader never loaded.
    nonisolated private static func trashResults(_ items: [LibraryItem], query: String, kind: ItemKind?) -> LibrarySearchResults {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = items.filter { item in
            if let kind, item.kind != kind { return false }
            return terms.allSatisfy { term in
                item.title.localizedStandardContains(term) || item.preview.localizedStandardContains(term)
            }
        }
        return LibrarySearchResults(query: query, items: matching)
    }

    /// Filters and reorders rows that are already in memory; nothing is re-read
    /// from disk. At the default options this returns the results untouched, so
    /// the search's relevance order and the list's natural order both survive.
    nonisolated private static func applying(_ options: LibraryListOptions, to results: LibrarySearchResults, hasQuery: Bool) -> LibrarySearchResults {
        var items = results.items
        if options.hasFilters { items = items.filter(options.matches) }
        if options.sortField != .updated || options.ascending { items = options.sorted(items) }
        return LibrarySearchResults(query: results.query, items: items, presentations: results.presentations)
    }

    deinit { searchTask?.cancel() }

    var selectedItem: LibraryItem? {
        guard let id = selectedID else { return nil }
        return snapshot.items.first { $0.id == id } ?? snapshot.trashed.first { $0.id == id }
    }

    func items(for ids: Set<String>) -> [LibraryItem] {
        guard !ids.isEmpty else { return [] }
        return snapshot.items.filter { ids.contains($0.id) } + snapshot.trashed.filter { ids.contains($0.id) }
    }
    var inboxCount: Int { snapshot.items.filter { $0.collectionID == nil }.count }
    var totalBytes: Int64 { snapshot.items.reduce(0) { $0 + $1.byteCount } }

    func collectionName(_ id: String?) -> String {
        snapshot.collections.first { $0.id == id }?.name ?? "待整理"
    }

    func load() async {
        guard repository == nil else { return }
        var restored = false
        do {
            // Applies a staged restore before the database is opened, so the live
            // library is never swapped while SQLite holds it.
            restored = try LibraryBackupStore.applyPendingRestore(in: root)
        } catch {
            errorMessage = error.localizedDescription
            status = "从备份恢复失败"
        }
        do {
            let root = root
            repository = try await Task.detached { try LibraryRepository(root: root) }.value
            try await reload()
            ready = true
            refreshBackups()
            status = restored ? "已从备份恢复，原资料库保留为 \(LibraryBackupStore.safetyCopyName)" : "所有资料仅保存在这台 Mac"
            await backupIfDue()
            purgeExpiredTrash()
            backfillFingerprints()
        } catch { errorMessage = error.localizedDescription; status = "资料库打开失败" }
    }

    /// Items imported before version 7 have no fingerprint, so duplicate detection
    /// would miss them. Hashing happens in the background, a batch at a time.
    private func backfillFingerprints() {
        Task { [weak self] in
            while let repository = self?.repository, !Task.isCancelled {
                let count = (try? await repository.backfillFingerprints()) ?? 0
                if count == 0 || Task.isCancelled { return }
            }
        }
    }

    /// Trashed items past the retention window are removed on launch, never on a
    /// user action, so a long-idle library still reclaims disk space.
    private func purgeExpiredTrash() {
        guard let repository else { return }
        Task {
            do {
                let report = try await repository.purgeExpiredTrash()
                guard report.deleted > 0 else { return }
                try await reload()
                status = "已清理 \(report.deleted) 项超过 \(LibraryRetention.trashDays) 天的回收站资料"
                if !report.warnings.isEmpty { errorMessage = report.warnings.joined(separator: "\n\n") }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: 备份与恢复

    func refreshBackups() {
        backups = (try? LibraryBackupStore.backups(in: root)) ?? []
        hasPendingRestore = LibraryBackupStore.pendingRestore(in: root) != nil
    }

    var backupDirectory: URL { LibraryBackupStore.directory(in: root) }

    /// One backup a day; the library is opened often enough that a launch-based
    /// schedule needs no timer.
    func backupIfDue() async {
        if let newest = backups.first, Date().timeIntervalSince(newest.date) < 24 * 60 * 60 { return }
        await createBackup()
    }

    func createBackup() async {
        guard let repository, !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let backup = try await repository.createBackup()
            refreshBackups()
            status = "已备份 \(backup.name)"
        } catch { errorMessage = error.localizedDescription }
    }

    /// Validates the file and stages it; nothing changes until the next launch.
    func prepareRestore(from url: URL) {
        do {
            try LibraryBackupStore.stageRestore(from: url, in: root)
            pendingRestoreName = url.lastPathComponent
            refreshBackups()
            status = "下次启动时恢复 \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelPendingRestore() {
        do {
            try LibraryBackupStore.cancelPendingRestore(in: root)
            pendingRestoreName = ""
            refreshBackups()
            status = "已取消恢复"
        } catch { errorMessage = error.localizedDescription }
    }

    func revealBackups() {
        NSWorkspace.shared.open((try? LibraryBackupStore.makeDirectory(in: root)) ?? root)
    }

    func selectVisibleItem() {
        let visible = Set(displayedItems.map(\.id))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
        if selection.isEmpty, let first = displayedItems.first?.id { selection = [first] }
    }

    func navigate(_ target: LibraryScope) {
        pendingReading = nil
        scope = target
        kindFilter = nil
    }

    private var currentReadingLocation: ReadingLocation? {
        guard let selectedID else { return nil }
        let fragment = readingRequest?.itemID == selectedID ? readingRequest?.fragment : nil
        return ReadingLocation(itemID: selectedID, fragment: fragment, scope: scope, query: query, kind: kindFilter)
    }

    func followMarkdownLink(_ url: URL, from item: LibraryItem) {
        do {
            switch try MarkdownLinks.resolve(url, from: item, items: snapshot.items, root: root) {
            case .web(let url):
                NSWorkspace.shared.open(url)
            case .item(let id, let fragment):
                guard let target = snapshot.items.first(where: { $0.id == id }) else { throw LibraryError.message("目标资料已不存在") }
                if let fragment, !fragment.isEmpty, !target.usesMarkdown {
                    throw LibraryError.message("标题跳转适用于 Markdown 文档和笔记。请直接打开此文件查看内容。")
                }
                if let location = currentReadingLocation { backHistory.append(location) }
                forwardHistory = []
                // A settled result already containing the target needs no list rebuild.
                // Pending searches still show old rows, so they must not take this path.
                let keepResults = !isSearching && displayedItems.contains(where: { $0.id == id })
                applyReadingLocation(ReadingLocation(itemID: id, fragment: fragment,
                    scope: keepResults ? scope : target.collectionID.map(LibraryScope.collection) ?? .inbox,
                    query: keepResults ? query : "", kind: keepResults ? kindFilter : nil))
            case .localFile(let url, let fragment):
                if let fragment, !fragment.isEmpty {
                    throw LibraryError.message("这个文件尚未导入资料库。请先导入，再使用文档内的标题跳转。")
                }
                Task {
                    do {
                        try await Task.detached {
                            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                                throw LibraryError.message("此链接不是普通文件，请在 Finder 中查看目录。")
                            }
                            guard FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryError.message("无法读取目标文件，请检查文件权限。") }
                        }.value
                        linkedFilePreview = LinkedFilePreview(url: url)
                    } catch { errorMessage = "本地链接未能打开：\(url.lastPathComponent)\n\(error.localizedDescription)" }
                }
            case .sourceFile(let url, let position, let id):
                linkedFilePreview = LinkedFilePreview(url: url, position: position,
                    title: snapshot.items.first(where: { $0.id == id })?.title, isManaged: id != nil)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func goBack() {
        guard let target = backHistory.popLast() else { return }
        if let location = currentReadingLocation { forwardHistory.append(location) }
        applyReadingLocation(target)
    }

    func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        if let location = currentReadingLocation { backHistory.append(location) }
        applyReadingLocation(target)
    }

    private func applyReadingLocation(_ location: ReadingLocation) {
        let request = ReadingRequest(itemID: location.itemID, fragment: location.fragment)
        if scope == location.scope, query == location.query, kindFilter == location.kind,
           !isSearching, displayedItems.contains(where: { $0.id == location.itemID }) {
            pendingReading = nil
            selectedID = location.itemID
            readingRequest = request
            return
        }
        if scope != location.scope { scope = location.scope }
        if query != location.query { query = location.query }
        if kindFilter != location.kind { kindFilter = location.kind }
        selectedID = location.itemID
        readingRequest = request; pendingReading = request
        scheduleSearch()
    }

    func readingAnchor(for id: String) -> ReadingAnchor? {
        readingAnchors[id]
    }

    func rememberReadingAnchor(_ anchor: ReadingAnchor, for id: String) {
        readingAnchors[id] = anchor
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "将文件复制到个人资料库"
        panel.message = "原文件会保留。每个文件最大 200 MB，导入后可整理到目录。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入资料"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.importFiles(panel.urls) }
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> Task<Void, Never>? {
        guard ready, !isImporting, let repository, !urls.isEmpty else { return nil }
        isImporting = true
        status = "正在核对 \(urls.count) 个文件…"
        return Task {
            defer { isImporting = false }
            do {
                let preview = try await repository.previewImport(urls)
                if preview.pending.isEmpty {
                    errorMessage = preview.failures.joined(separator: "\n\n")
                    status = "没有可导入的文件"
                    return
                }
                // Only stop for a prompt when there is something to decide; a first
                // import of new files should not cost an extra click.
                if preview.hasDuplicates {
                    pendingImport = preview
                    status = "\(preview.duplicates.count) 个文件已在库中，等待确认"
                    return
                }
                try await finishImport(preview, skippingDuplicates: false)
            } catch { errorMessage = error.localizedDescription; status = "导入未完成" }
        }
    }

    @discardableResult
    func resolvePendingImport(keepDuplicates: Bool) -> Task<Void, Never>? {
        guard let preview = pendingImport, let repository else { return nil }
        pendingImport = nil
        isImporting = true
        status = "正在导入…"
        return Task {
            defer { isImporting = false }
            do { try await finishImport(preview, skippingDuplicates: !keepDuplicates) }
            catch { errorMessage = error.localizedDescription; status = "导入未完成" }
        }
    }

    func cancelPendingImport() {
        guard pendingImport != nil else { return }
        pendingImport = nil
        status = "已取消导入"
    }

    private func finishImport(_ preview: LibraryRepository.ImportPreview, skippingDuplicates: Bool) async throws {
        guard let repository else { return }
        let report = try await repository.importFiles(preview, skippingDuplicates: skippingDuplicates)
        try await reload()
        // Import publishes new data; current navigation and selection still belong to the reader.
        var parts: [String] = []
        if !report.importedIDs.isEmpty { parts.append("已导入 \(report.importedIDs.count) 项") }
        if !report.skipped.isEmpty { parts.append("跳过 \(report.skipped.count) 个重复文件") }
        if !report.failures.isEmpty { parts.append("\(report.failures.count) 项未成功") }
        status = parts.isEmpty ? "没有导入内容" : parts.joined(separator: "，")
        if !report.warnings.isEmpty { status += "；部分配图未保存" }
        let messages = report.failures + report.warnings.map { "配图提示：" + $0 }
        if !messages.isEmpty { errorMessage = messages.joined(separator: "\n\n") }
    }

    func newNote(kind: ItemKind = .note) {
        guard ready, draft == nil, !isImporting else { return }
        draft = NoteDraft(kind: kind)
    }
    func edit(_ item: LibraryItem) {
        guard ready, draft == nil, !isImporting else { return }
        guard !item.isTrashed else {
            status = "回收站中的资料不能编辑，请先恢复"
            return
        }
        if item.textLoaded {
            draft = NoteDraft(itemID: item.id, title: item.title, body: item.text, kind: item.kind)
            return
        }
        status = "正在载入正文…"
        Task {
            await loadBody(item.id)
            guard draft == nil, selectedID == item.id,
                  let current = snapshot.items.first(where: { $0.id == item.id }), current.textLoaded else { return }
            status = ""
            draft = NoteDraft(itemID: current.id, title: current.title, body: current.text, kind: current.kind)
        }
    }

    func save(_ draft: NoteDraft) async throws {
        guard let repository else { throw LibraryError.message("资料库尚未就绪") }
        guard !isSavingNote else { throw LibraryError.message("正在保存，请稍候") }
        isSavingNote = true
        defer { isSavingNote = false }
        let collection: String?
        if case .collection(let id) = scope { collection = id } else { collection = nil }
        let id = try await repository.saveNote(id: draft.itemID, title: draft.title, body: draft.body, kind: draft.kind, collectionID: collection)
        bodyCache[id] = draft.body
        try await reload()
        scope = draft.kind == .note ? .notes : .thoughts
        query = ""; kindFilter = nil; selectedID = id
        self.draft = nil
        status = "\(draft.kind.label)已保存到本机"
    }

    func createCollection(_ name: String) async throws {
        guard let repository else { throw LibraryError.message("资料库尚未就绪") }
        let id = try await repository.createCollection(name: name)
        try await reload()
        navigate(.collection(id))
        showNewCollection = false
    }

    @discardableResult
    func favorite(_ item: LibraryItem) -> Task<Void, Never>? {
        setFavorite(Set([item.id]), value: !item.favorite)
    }

    @discardableResult
    func setFavorite(_ ids: Set<String>, value: Bool) -> Task<Void, Never>? {
        guard ready, !isBatchUpdating, let repository, !ids.isEmpty else { return nil }
        isBatchUpdating = true
        let count = ids.count
        return Task {
            defer { isBatchUpdating = false }
            do {
                try await repository.setFavorite(ids: Array(ids), value: value)
                suppressSearch = true
                var items = snapshot.items
                for index in items.indices where ids.contains(items[index].id) {
                    items[index].favorite = value
                }
                snapshot.items = items
                suppressSearch = false
                scheduleSearch()
                if count == 1 {
                    status = value ? "已收藏" : "已取消收藏"
                } else {
                    status = value ? "已收藏 \(count) 项" : "已取消收藏 \(count) 项"
                }
            } catch {
                errorMessage = error.localizedDescription
                status = "收藏未完成"
            }
        }
    }

    // MARK: 标签

    /// The sheet works on a fixed list of items so a scope or search change
    /// behind it cannot retarget the tags.
    struct TagEditorRequest: Identifiable, Equatable {
        let id = UUID()
        let itemIDs: [String]
    }

    @Published var tagEditorRequest: TagEditorRequest?

    var tagEditorItems: [LibraryItem] { items(for: Set(tagEditorRequest?.itemIDs ?? [])) }

    func beginTagEditing(ids: Set<String>) {
        guard ready, !isBatchUpdating, !ids.isEmpty else { return }
        tagEditorRequest = TagEditorRequest(itemIDs: items(for: ids).map(\.id))
    }

    func endTagEditing() { tagEditorRequest = nil }

    /// Tags the whole selection the same way, so the sheet's checkboxes always
    /// mean "applies to every selected item".
    @discardableResult
    func applyTags(_ names: [String], to ids: [String]) -> Task<Void, Never>? {
        guard ready, !isBatchUpdating, let repository, !ids.isEmpty else { return nil }
        isBatchUpdating = true
        tagEditorRequest = nil
        let cleaned = names.sorted()
        return Task {
            defer { isBatchUpdating = false }
            do {
                try await repository.setTags(cleaned, for: ids)
                try await reload()
                status = cleaned.isEmpty
                    ? (ids.count == 1 ? "已清除标签" : "已清除 \(ids.count) 项资料的标签")
                    : (ids.count == 1 ? "已设置标签" : "已为 \(ids.count) 项资料设置标签")
            } catch {
                errorMessage = error.localizedDescription
                status = "标签未保存"
            }
        }
    }

    @discardableResult
    func deleteTag(_ tag: LibraryTag) -> Task<Void, Never>? {
        guard ready, !isBatchUpdating, let repository else { return nil }
        isBatchUpdating = true
        return Task {
            defer { isBatchUpdating = false }
            do {
                try await repository.deleteTag(id: tag.id)
                if case .tag(let name) = scope, name.caseInsensitiveCompare(tag.name) == .orderedSame {
                    navigate(.all)
                }
                try await reload()
                status = "已删除标签「\(tag.name)」，资料都还在"
            } catch {
                errorMessage = error.localizedDescription
                status = "标签未删除"
            }
        }
    }

    @discardableResult
    func renameTag(_ tag: LibraryTag, to name: String) -> Task<Void, Never>? {
        guard ready, !isBatchUpdating, let repository else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else { return nil }
        isBatchUpdating = true
        return Task {
            defer { isBatchUpdating = false }
            do {
                try await repository.renameTag(id: tag.id, to: trimmed)
                if case .tag(let current) = scope, current.caseInsensitiveCompare(tag.name) == .orderedSame {
                    scope = .tag(trimmed)
                }
                try await reload()
                status = "已重命名为「\(trimmed)」"
            } catch {
                errorMessage = error.localizedDescription
                status = "标签未重命名"
            }
        }
    }

    @discardableResult
    func organize(_ item: LibraryItem, into collectionID: String?) -> Task<Void, Never>? {
        organize(Set([item.id]), into: collectionID)
    }

    @discardableResult
    func organize(_ ids: Set<String>, into collectionID: String?) -> Task<Void, Never>? {
        guard ready, !isBatchUpdating, let repository, !ids.isEmpty else { return nil }
        isBatchUpdating = true
        let count = ids.count
        let target = collectionName(collectionID)
        return Task {
            defer { isBatchUpdating = false }
            do {
                try await repository.organize(ids: Array(ids), collectionID: collectionID)
                let title = snapshot.items.first { ids.contains($0.id) }?.title ?? ""
                suppressSearch = true
                var items = snapshot.items
                for index in items.indices where ids.contains(items[index].id) {
                    items[index].collectionID = collectionID
                }
                snapshot.items = items
                let message = count == 1 ? "将「\(title)」归入「\(target)」" : "将 \(count) 项资料归入「\(target)」"
                snapshot.activities.insert(LibraryActivity(id: UUID().uuidString, message: message, date: Date()), at: 0)
                if snapshot.activities.count > 200 { snapshot.activities.removeLast(snapshot.activities.count - 200) }
                suppressSearch = false
                scheduleSearch()
                status = count == 1 ? "已归入「\(target)」" : "已将 \(count) 项归入「\(target)」"
            } catch {
                errorMessage = error.localizedDescription
                status = "整理未完成"
            }
        }
    }

    /// The delete command moves items to the trash. Only the trash view destroys them.
    func requestTrash(_ ids: Set<String>) {
        guard ready, !isDeleting, !isBatchUpdating, !ids.isEmpty else { return }
        pendingDeletionIsPermanent = false
        pendingDeletion = ids
    }

    func requestTrashSelection() {
        requestTrash(selection)
    }

    /// Requests the one action that removes managed copies. Used from the trash only.
    func requestPermanentDelete(_ ids: Set<String>) {
        guard ready, !isDeleting, !isBatchUpdating, !ids.isEmpty else { return }
        pendingDeletionIsPermanent = true
        pendingDeletion = ids
    }

    func cancelDelete() {
        pendingDeletion = []
        pendingDeletionIsPermanent = false
    }

    func confirmDelete(_ requested: Set<String>? = nil) async {
        let ids = requested ?? pendingDeletion
        let permanent = pendingDeletionIsPermanent
        pendingDeletion = []
        pendingDeletionIsPermanent = false
        guard !ids.isEmpty, !isDeleting, !isBatchUpdating, let repository else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            if permanent {
                let report = try await repository.permanentlyDelete(ids: Array(ids))
                undoableTrash = []
                selection.subtract(ids)
                try await reload()
                if report.deleted == 0 {
                    status = "没有可删除的资料"
                } else if report.warnings.isEmpty {
                    status = "已彻底删除 \(report.deleted) 项，原文件保留"
                } else {
                    status = "已彻底删除 \(report.deleted) 项，\(report.warnings.count) 个副本未清理"
                }
                if !report.warnings.isEmpty { errorMessage = report.warnings.joined(separator: "\n\n") }
            } else {
                let count = try await repository.moveToTrash(ids: Array(ids))
                selection.subtract(ids)
                try await reload()
                guard count > 0 else {
                    status = "没有可移到回收站的资料"
                    return
                }
                undoableTrash = ids
                status = "已将 \(count) 项移到回收站，\(LibraryRetention.trashDays) 天内可恢复"
            }
        } catch {
            errorMessage = error.localizedDescription
            status = permanent ? "彻底删除未完成" : "移到回收站未完成"
        }
    }

    /// Puts back everything from the most recent trash action.
    @discardableResult
    func undoTrash() -> Task<Void, Never>? {
        restore(undoableTrash, clearsUndo: true)
    }

    func dismissUndoTrash() {
        undoableTrash = []
    }

    /// Emptying the trash destroys copies, so it needs its own confirmation.
    func requestEmptyTrash() {
        guard trashedCount > 0, !isDeleting else { return }
        confirmEmptyTrash = true
    }

    @discardableResult
    func restoreFromTrash(_ ids: Set<String>) -> Task<Void, Never>? {
        restore(ids, clearsUndo: false)
    }

    private func restore(_ ids: Set<String>, clearsUndo: Bool) -> Task<Void, Never>? {
        guard ready, !isDeleting, !isBatchUpdating, let repository, !ids.isEmpty else { return nil }
        isDeleting = true
        return Task {
            defer { isDeleting = false }
            do {
                let count = try await repository.restoreFromTrash(ids: Array(ids))
                undoableTrash = clearsUndo ? [] : undoableTrash.subtracting(ids)
                try await reload()
                status = count > 0 ? "已恢复 \(count) 项资料" : "没有可恢复的资料"
            } catch {
                errorMessage = error.localizedDescription
                status = "恢复未完成"
            }
        }
    }

    @discardableResult
    func emptyTrash() -> Task<Void, Never>? {
        guard ready, !isDeleting, !isBatchUpdating, let repository, trashedCount > 0 else { return nil }
        isDeleting = true
        return Task {
            defer { isDeleting = false }
            do {
                let report = try await repository.emptyTrash()
                undoableTrash = []
                selection = []
                try await reload()
                status = report.warnings.isEmpty
                    ? "已清空回收站，删除 \(report.deleted) 项"
                    : "已清空回收站，\(report.warnings.count) 个副本未清理"
                if !report.warnings.isEmpty { errorMessage = report.warnings.joined(separator: "\n\n") }
            } catch {
                errorMessage = error.localizedDescription
                status = "清空回收站未完成"
            }
        }
    }

    func fileURL(_ item: LibraryItem) throws -> URL {
        guard let repository else { throw LibraryError.message("资料库尚未就绪") }
        return try repository.fileURL(for: item)
    }

    @Published private(set) var imageDirectoryRevision = 0
    @Published private(set) var isCopyingImages = false

    func copyImages(_ item: LibraryItem) {
        guard ready, !isCopyingImages, let repository else { return }
        isCopyingImages = true
        status = "正在保存配图…"
        Task {
            defer { isCopyingImages = false }
            do {
                let report = try await repository.copyMarkdownImages(id: item.id)
                try await reload()
                imageDirectoryRevision += 1
                status = report.summary
                if !report.failures.isEmpty { errorMessage = report.failures.joined(separator: "\n\n") }
            } catch { errorMessage = error.localizedDescription; status = "配图保存未完成" }
        }
    }

    func chooseImageDirectory(_ item: LibraryItem) {
        guard ready, !isCopyingImages, let repository else { return }
        let panel = NSOpenPanel()
        panel.title = "选择图片目录"
        panel.message = "选择 Markdown 原文所在的文件夹。引用的图片会复制进资料库；已保存的配图也会从此目录更新，原文件保留。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此目录"
        if let path = item.imageBasePath { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                guard let self, !self.isCopyingImages else { return }
                self.isCopyingImages = true
                defer { self.isCopyingImages = false }
                do {
                    let report = try await repository.setImageBaseDirectory(id: item.id, directory: directory)
                    try await self.reload()
                    self.imageDirectoryRevision += 1
                    self.status = "已更新图片目录，" + report.summary
                    if !report.failures.isEmpty { self.errorMessage = report.failures.joined(separator: "\n\n") }
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func open(_ item: LibraryItem) {
        do {
            guard NSWorkspace.shared.open(try fileURL(item)) else { throw LibraryError.message("系统未能打开此文件，请检查是否安装了相应应用。") }
        } catch { errorMessage = error.localizedDescription }
    }

    func reveal(_ item: LibraryItem) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try fileURL(item)]) }
        catch { errorMessage = error.localizedDescription }
    }

    func export(_ item: LibraryItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let body: String
                    if item.textLoaded {
                        body = item.text
                    } else if let repository = self.repository {
                        body = try await repository.body(for: item.id) ?? ""
                    } else {
                        throw LibraryError.message("资料库尚未就绪")
                    }
                    try ("# \(item.title)\n\n\(body)\n").write(to: url, atomically: true, encoding: .utf8)
                    self.status = "已导出 Markdown"
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func loadBody(_ id: String) async {
        guard let repository else { return }
        if let cached = bodyCache[id] {
            suppressSearch = true
            applyBody(cached, to: id)
            suppressSearch = false
            return
        }
        if let item = snapshot.items.first(where: { $0.id == id }), item.textLoaded { return }
        guard !bodyLoadingIDs.contains(id) else { return }
        bodyLoadingIDs.insert(id)
        defer { bodyLoadingIDs.remove(id) }
        do {
            guard let body = try await repository.body(for: id) else {
                throw LibraryError.message("资料不存在，可能已被删除")
            }
            bodyCache[id] = body
            suppressSearch = true
            applyBody(body, to: id)
            suppressSearch = false
        } catch {
            if selectedID == id {
                errorMessage = error.localizedDescription
                status = "正文载入失败"
            }
        }
    }

    private func applyBody(_ body: String, to id: String) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
        snapshot.items[index].text = body
        snapshot.items[index].textLoaded = true
    }

    private func reload() async throws {
        guard let repository else { return }
        let cached = bodyCache
        let next = try await repository.snapshot()
        let ids = Set(next.items.map(\.id))
        bodyCache = cached.filter { ids.contains($0.key) }
        readingAnchors = readingAnchors.filter { ids.contains($0.key) }
        suppressSearch = true
        snapshot = next
        for (id, body) in bodyCache { applyBody(body, to: id) }
        suppressSearch = false
        scheduleSearch()
    }
}
