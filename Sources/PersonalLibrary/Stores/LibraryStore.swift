import AppKit
import Foundation
import LibraryCore
import SwiftUI
import UniformTypeIdentifiers

enum LibraryScope: Hashable, Sendable {
    case recent, all, inbox, notes, thoughts, favorites, history, collection(String)
    var title: String {
        switch self {
        case .recent: return "最近添加"
        case .all: return "全部资料"
        case .inbox: return "待整理"
        case .notes: return "我的笔记"
        case .thoughts: return "随笔"
        case .favorites: return "已收藏"
        case .history: return "整理记录"
        case .collection: return "目录"
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
    @Published var snapshot = LibrarySnapshot() { didSet { scheduleSearch() } }
    @Published var scope: LibraryScope = .all { didSet { if oldValue != scope { scheduleSearch() } } }
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            if scope == .history && !query.isEmpty { navigate(.all) }
            scheduleSearch(debounce: true)
        }
    }
    @Published var kindFilter: ItemKind? { didSet { if oldValue != kindFilter { scheduleSearch() } } }
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
    @Published private(set) var isDeleting = false
    @Published private(set) var isBatchUpdating = false
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
    @Published var isSavingNote = false
    @Published var ready = false
    @Published var focusSearch = false
    @Published var showNewCollection = false
    let root: URL
    private var repository: LibraryRepository?
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
        return scope.title
    }

    var displayedItems: [LibraryItem] { searchResults.items }

    /// One cancellable worker per request; input and SwiftUI rendering never scan full bodies.
    private func scheduleSearch(debounce: Bool = false) {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let items = snapshot.items
        let scope = scope
        let kind = kindFilter
        let query = query
        isSearching = scope != .history
        searchTask = Task { [weak self] in
            do {
                if debounce && !query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    var candidates = items.filter { item in
                        switch scope {
                        case .all, .recent: return true
                        case .inbox: return item.collectionID == nil
                        case .notes: return item.kind == .note
                        case .thoughts: return item.kind == .thought
                        case .favorites: return item.favorite
                        case .collection(let id): return item.collectionID == id
                        case .history: return false
                        }
                    }
                    if scope == .recent { candidates = Array(candidates.sorted { $0.createdAt > $1.createdAt }.prefix(50)) }
                    if let kind { candidates = candidates.filter { $0.kind == kind } }
                    return try LibrarySearch.search(candidates, query: query)
                }
                let results = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
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

    deinit { searchTask?.cancel() }

    var selectedItem: LibraryItem? {
        guard let id = selectedID else { return nil }
        return snapshot.items.first { $0.id == id }
    }

    func items(for ids: Set<String>) -> [LibraryItem] {
        guard !ids.isEmpty else { return [] }
        return snapshot.items.filter { ids.contains($0.id) }
    }
    var inboxCount: Int { snapshot.items.filter { $0.collectionID == nil }.count }
    var totalBytes: Int64 { snapshot.items.reduce(0) { $0 + $1.byteCount } }

    func collectionName(_ id: String?) -> String {
        snapshot.collections.first { $0.id == id }?.name ?? "待整理"
    }

    func load() async {
        guard repository == nil else { return }
        do {
            let root = root
            repository = try await Task.detached { try LibraryRepository(root: root) }.value
            try await reload()
            ready = true
            status = "所有资料仅保存在这台 Mac"
        } catch { errorMessage = error.localizedDescription; status = "资料库打开失败" }
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
        status = "正在导入 \(urls.count) 个文件并提取正文…"
        return Task {
            defer { isImporting = false }
            do {
                let report = try await repository.importFiles(urls)
                try await reload()
                // Import publishes new data; current navigation and selection still belong to the reader.
                status = "已导入 \(report.importedIDs.count) 项" + (report.failures.isEmpty ? "，原文件已保留" : "，\(report.failures.count) 项未成功")
                if !report.warnings.isEmpty { status += "；部分配图未保存" }
                let messages = report.failures + report.warnings.map { "配图提示：" + $0 }
                if !messages.isEmpty { errorMessage = messages.joined(separator: "\n\n") }
            } catch { errorMessage = error.localizedDescription; status = "导入未完成" }
        }
    }

    func newNote(kind: ItemKind = .note) {
        guard ready, draft == nil, !isImporting else { return }
        draft = NoteDraft(kind: kind)
    }
    func edit(_ item: LibraryItem) {
        guard ready, draft == nil, !isImporting else { return }
        draft = NoteDraft(itemID: item.id, title: item.title, body: item.text, kind: item.kind)
    }

    func save(_ draft: NoteDraft) async throws {
        guard let repository else { throw LibraryError.message("资料库尚未就绪") }
        guard !isSavingNote else { throw LibraryError.message("正在保存，请稍候") }
        isSavingNote = true
        defer { isSavingNote = false }
        let collection: String?
        if case .collection(let id) = scope { collection = id } else { collection = nil }
        let id = try await repository.saveNote(id: draft.itemID, title: draft.title, body: draft.body, kind: draft.kind, collectionID: collection)
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
                try await reload()
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
                try await reload()
                status = count == 1 ? "已归入「\(target)」" : "已将 \(count) 项归入「\(target)」"
            } catch {
                errorMessage = error.localizedDescription
                status = "整理未完成"
            }
        }
    }

    func requestDelete(_ ids: Set<String>) {
        guard ready, !isDeleting, !isBatchUpdating, !ids.isEmpty else { return }
        pendingDeletion = ids
    }

    func requestDeleteSelection() {
        requestDelete(selection)
    }

    func cancelDelete() {
        pendingDeletion = []
    }

    func confirmDelete(_ requested: Set<String>? = nil) async {
        let ids = requested ?? pendingDeletion
        guard !ids.isEmpty, !isDeleting, !isBatchUpdating, let repository else { return }
        pendingDeletion = []
        isDeleting = true
        defer { isDeleting = false }
        do {
            let report = try await repository.delete(ids: Array(ids))
            selection.subtract(ids)
            try await reload()
            if report.deleted == 0 {
                status = "没有可删除的资料"
            } else if report.warnings.isEmpty {
                status = "已删除 \(report.deleted) 项资料，原文件保留"
            } else {
                status = "已删除 \(report.deleted) 项，\(report.warnings.count) 个副本未清理"
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "删除未完成"
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
            guard result == .OK, let url = panel.url else { return }
            do {
                try ("# \(item.title)\n\n\(item.text)\n").write(to: url, atomically: true, encoding: .utf8)
                self?.status = "已导出 Markdown"
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func reload() async throws {
        guard let repository else { return }
        snapshot = try await repository.snapshot()
    }
}
