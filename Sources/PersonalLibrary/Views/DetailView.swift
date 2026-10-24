import AppKit
import LibraryCore
import Quartz
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: LibraryStore
    @ViewState<Bool> private var showSystemPreview = false
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findMatches: [DocumentMatch] = []
    @State private var findIndex = 0
    @State private var findGeneration = 0
    @State private var markdownSections: [String] = []
    @State private var currentAnchor: ReadingAnchor?
    @State private var visibleChunks: Set<Int> = []
    @State private var visibleSections: Set<Int> = []
    @State private var restoreAnchor: ReadingAnchor?
    @State private var isRestoringPosition = false
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.scope != .history, store.selection.count > 1 {
                MultiSelectionDetail(store: store)
            } else if let item = store.selectedItem, store.scope != .history {
                reader(item)
            } else {
                EmptyLibraryView(title: "每一份资料，都触手可及", message: "选择一份文件或笔记，\n在这里查看内容与整理归属。", symbol: "doc.text.magnifyingglass")
            }
        }
        .toolbar { toolbarContent }
        .onChange(of: store.selectedID) { oldID, newID in
            if let oldID, let currentAnchor {
                store.rememberReadingAnchor(currentAnchor, for: oldID)
            }
            currentAnchor = nil
            showSystemPreview = false
            closeFind()
            markdownSections = []
            visibleChunks = []
            visibleSections = []
            restoreAnchor = newID.flatMap { store.readingAnchor(for: $0) }
            isRestoringPosition = restoreAnchor != nil
        }
        .onChange(of: findQuery) { _, _ in scheduleFind() }
        .onChange(of: findVisible) { _, visible in
            findFocused = visible
            if visible { scheduleFind() }
        }
        .onDisappear {
            if let id = store.selectedID, let currentAnchor {
                store.rememberReadingAnchor(currentAnchor, for: id)
            }
        }
    }

    private func reader(_ item: LibraryItem) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if item.isTrashed { trashBanner(item) }
                if findVisible { findBar(proxy: proxy) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(item).id(MarkdownScrollTarget.top)
                        if let note = item.extractionNote {
                            Label(note, systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        }
                        searchExcerpt(item)
                        readerBody(item, proxy: proxy)
                    }
                    .padding(28)
                }
            }
            .task(id: item.id) {
                if restoreAnchor == nil {
                    restoreAnchor = store.readingAnchor(for: item.id)
                    isRestoringPosition = restoreAnchor != nil
                }
                guard item.kind != .image, item.fileExtension != "PDF" else {
                    isRestoringPosition = false
                    return
                }
                await store.loadBody(item.id)
                if findVisible { scheduleFind() }
                await restoreReadingPosition(for: item, proxy: proxy)
            }
        }
        .id(item.id)
    }

    @ViewBuilder
    private func searchExcerpt(_ item: LibraryItem) -> some View {
        if let excerpt = store.searchResults.presentations[item.id]?.matchingExcerpt {
            VStack(alignment: .leading, spacing: 12) {
                Label("搜索命中内容", systemImage: "text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(highlight(excerpt))
                    .font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ item: LibraryItem, proxy: ScrollViewProxy) -> some View {
        if !item.isEditable && (showSystemPreview || item.kind == .image || item.fileExtension == "PDF") {
            systemPreview(item)
        } else if !item.textLoaded {
            ProgressView("正在载入正文…")
                .frame(maxWidth: .infinity, minHeight: 260)
        } else if item.text.isEmpty {
            EmptyLibraryView(title: "使用系统查看完整内容", message: "点击「预览文件」或「打开文件」。", symbol: "doc.viewfinder")
                .frame(minHeight: 260)
        } else if item.usesMarkdown {
            markdownReader(item, proxy: proxy)
        } else {
            BodyTextView(text: item.text,
                         highlight: findVisible ? findQuery : "",
                         onChunkVisible: { index in
                             visibleChunks.insert(index)
                             record(anchor: visibleChunks.min().map(ReadingAnchor.bodyChunk), for: item)
                         },
                         onChunkHidden: { index in
                             visibleChunks.remove(index)
                             record(anchor: visibleChunks.min().map(ReadingAnchor.bodyChunk), for: item)
                         })
        }
    }

    @ViewBuilder
    private func systemPreview(_ item: LibraryItem) -> some View {
        if let url = try? store.fileURL(item) {
            SystemPreview(url: url).frame(minHeight: 460).id(item.id)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label("文件不在原位置，请恢复备份或重新导入。", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary).font(.system(size: 12))
        }
    }

    private func markdownReader(_ item: LibraryItem, proxy: ScrollViewProxy) -> some View {
        MarkdownReader(source: item.text,
                       imageContext: .init(itemID: item.id,
                                           basePath: item.imageBasePath,
                                           revision: store.imageDirectoryRevision,
                                           attachments: item.imageAttachments),
                       imageIssues: item.imageAttachmentIssues,
                       isCopyingImages: store.isCopyingImages,
                       chooseImageDirectory: { store.chooseImageDirectory(item) },
                       copyImages: { store.copyImages(item) },
                       readingRequest: store.readingRequest,
                       followLink: { store.followMarkdownLink($0, from: item) },
                       scrollTo: { proxy.scrollTo($0, anchor: .top) },
                       reportError: { store.errorMessage = $0 },
                       onStructure: { _, sections in
                           markdownSections = sections
                           if findVisible { scheduleFind() }
                       },
                       onSectionVisible: { index in
                           visibleSections.insert(index)
                           record(anchor: visibleSections.min().map(ReadingAnchor.markdownSection), for: item)
                       },
                       onSectionHidden: { index in
                           visibleSections.remove(index)
                           record(anchor: visibleSections.min().map(ReadingAnchor.markdownSection), for: item)
                       },
                       restoreSection: restoreSection(item),
                       onRestoreComplete: { isRestoringPosition = false })
    }

    /// The topmost visible block wins, so the anchor follows what the reader
    /// actually sees instead of whichever lazy row happens to appear last.
    private func record(anchor: ReadingAnchor?, for item: LibraryItem) {
        guard !isRestoringPosition, !item.isTrashed, let anchor else { return }
        currentAnchor = anchor
        store.rememberReadingAnchor(anchor, for: item.id)
    }

    private func restoreSection(_ item: LibraryItem) -> Int? {
        guard isRestoringPosition, let anchor = restoreAnchor else { return nil }
        if case .markdownSection(let index) = anchor { return index }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.goBack() } label: { Label("返回上一份资料", systemImage: "chevron.left") }
                .disabled(store.backHistory.isEmpty).help("返回 · ⌘[")
                .keyboardShortcut("[", modifiers: .command)
            Button { store.goForward() } label: { Label("前进", systemImage: "chevron.right") }
                .disabled(store.forwardHistory.isEmpty).help("前进 · ⌘]")
                .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            detailActions
        }
    }

    @ViewBuilder
    private var detailActions: some View {
        if let item = store.selectedItem, store.scope != .history {
            Button { toggleFind() } label: {
                Label("在文中查找", systemImage: "text.magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .help("在文中查找 · ⌘⌥F")
            .disabled(item.kind == .image || item.fileExtension == "PDF")
            Button { store.favorite(item) } label: {
                Label(item.favorite ? "取消收藏" : "收藏", systemImage: item.favorite ? "star.fill" : "star")
            }.help(item.favorite ? "取消收藏" : "收藏")
            Menu {
                if item.isTrashed {
                    Button { store.restoreFromTrash([item.id]) } label: { Label("移出回收站", systemImage: "arrow.uturn.backward") }
                    Button { store.export(item) } label: { Label("导出为 Markdown…", systemImage: "square.and.arrow.up") }
                } else if item.isEditable {
                    Button { store.edit(item) } label: { Label("编辑", systemImage: "square.and.pencil") }
                    Button { store.export(item) } label: { Label("导出为 Markdown…", systemImage: "square.and.arrow.up") }
                    Button { store.exportPackage(item) } label: { Label("导出资料包…", systemImage: "shippingbox") }
                } else {
                    Button { store.open(item) } label: { Label("打开文件", systemImage: "arrow.up.forward.app") }
                    Button { store.reveal(item) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                    Button { store.exportPackage(item) } label: { Label("导出资料包…", systemImage: "shippingbox") }
                }
            } label: { Label("资料操作", systemImage: "ellipsis") }
            .help("资料操作")
        }
    }

    private func trashBanner(_ item: LibraryItem) -> some View {
        HStack(spacing: 10) {
            Label("在回收站中，\(LibraryRetention.trashDays) 天后自动清理", systemImage: "trash")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("恢复") { store.restoreFromTrash([item.id]) }
                .help("移出回收站")
                .disabled(store.isDeleting)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
    }

    private func findBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
            TextField("在文中查找", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($findFocused)
                .onSubmit { advanceFind(proxy: proxy, by: 1) }
            Text(matchCountLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .leading)
            Button { advanceFind(proxy: proxy, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(findMatches.isEmpty)
            .help("上一个命中")
            Button { advanceFind(proxy: proxy, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(findMatches.isEmpty)
            .help("下一个命中")
            if let snippet = currentMatch?.snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 260, alignment: .leading)
            }
            Spacer()
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .help("关闭查找")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .onExitCommand { closeFind() }
    }

    private var matchCountLabel: String {
        guard !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "0/0" }
        guard !findMatches.isEmpty else { return "0/0" }
        let plus = findMatches.count >= DocumentFind.maximumMatches ? "+" : ""
        return "\(findIndex + 1)/\(findMatches.count)\(plus)"
    }

    private var currentMatch: DocumentMatch? {
        guard findMatches.indices.contains(findIndex) else { return nil }
        return findMatches[findIndex]
    }

    private func toggleFind() {
        if findVisible { closeFind() }
        else {
            findVisible = true
            findFocused = true
            scheduleFind()
        }
    }

    private func closeFind() {
        findGeneration += 1
        findVisible = false
        findQuery = ""
        findMatches = []
        findIndex = 0
        findFocused = false
    }

    private func scheduleFind() {
        findGeneration += 1
        let generation = findGeneration
        guard findVisible, let item = store.selectedItem,
              !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }
        let query = findQuery
        let text = item.text
        let sections = item.usesMarkdown ? markdownSections : nil
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard generation == findGeneration else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                DocumentFind.matches(in: text, query: query, markdownSections: sections)
            }.value
            guard generation == findGeneration else { return }
            findMatches = matches
            findIndex = 0
        }
    }

    private func advanceFind(proxy: ScrollViewProxy, by offset: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + offset + findMatches.count) % findMatches.count
        jump(to: findMatches[findIndex].anchor, proxy: proxy)
    }

    private func jump(to target: MarkdownScrollTarget, proxy: ScrollViewProxy) {
        proxy.scrollTo(target, anchor: .top)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func scrollTarget(for anchor: ReadingAnchor) -> MarkdownScrollTarget {
        switch anchor {
        case .markdownSection(let index): .section(index)
        case .bodyChunk(let index): .bodyChunk(index)
        }
    }

    private func restoreReadingPosition(for item: LibraryItem, proxy: ScrollViewProxy) async {
        guard let anchor = restoreAnchor else {
            isRestoringPosition = false
            return
        }
        // Markdown restores itself once the sections are parsed, because the
        // lazy stack has no scroll targets before that. It clears the flag.
        if item.usesMarkdown {
            if restoreSection(item) == nil { isRestoringPosition = false }
            return
        }
        defer { isRestoringPosition = false }
        if let request = store.readingRequest, request.itemID == item.id, request.fragment != nil { return }
        let target = scrollTarget(for: anchor)
        await Task.yield()
        proxy.scrollTo(target, anchor: .top)
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        proxy.scrollTo(target, anchor: .top)
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func header(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            FileBadge(item: item, large: true)
            Text(item.title).font(.system(size: 24, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            tagRow(item)
            Text("\(item.kind.label)  ·  \(item.updatedAt.formatted(date: .long, time: .omitted))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if item.isTrashed {
                    EmptyView()
                } else if item.isEditable {
                    Button { store.edit(item) } label: { Label("编辑\(item.kind.label)", systemImage: "square.and.pencil") }
                } else {
                    Button("打开文件") { store.open(item) }
                    Button { store.reveal(item) } label: { Image(systemName: "folder") }.help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
                    if !item.usesMarkdown && item.kind != .image && item.fileExtension != "PDF" {
                        Button(showSystemPreview ? "正文" : "预览文件") { showSystemPreview.toggle() }
                    }
                }
            }.controlSize(.small)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Menu {
                    Button("待整理") { store.organize(item, into: nil) }
                    ForEach(store.snapshot.collections) { collection in
                        Button(collection.name) { store.organize(item, into: collection.id) }
                    }
                    Divider()
                    Button("新建目录…") { store.showNewCollection = true }
                } label: { Text(store.collectionName(item.collectionID)).font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.top, 3)
        }
    }

    /// Tags double as a filter: clicking one opens that tag's list.
    private func tagRow(_ item: LibraryItem) -> some View {
        HStack(spacing: 6) {
            if item.tags.isEmpty {
                Text("没有标签").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(item.tags, id: \.self) { name in
                Button { store.navigate(.tag(name)) } label: {
                    Text("#" + name).font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("只看带 #\(name) 的资料")
            }
            if !item.isTrashed {
                Button { store.beginTagEditing(ids: [item.id]) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("添加标签")
                .accessibilityLabel("添加标签")
            }
            Spacer(minLength: 0)
        }
    }

    private func highlight(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for term in store.searchResults.query.split(whereSeparator: \.isWhitespace) {
            var range = result.startIndex..<result.endIndex
            while let found = result[range].range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) {
                result[found].foregroundColor = Color.accentColor
                result[found].font = .system(size: 13, weight: .bold)
                range = found.upperBound..<result.endIndex
            }
        }
        return result
    }
}

/// Quick Look owns only its native preview lifecycle; selection stays in SwiftUI.
private struct SystemPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // SwiftUI owns disposal; disable the second, window-driven close path.
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if nsView.previewItem?.previewItemURL != url { nsView.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) { nsView.close() }
}


private struct MultiSelectionDetail: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        let items = store.items(for: store.selection)
        let allFavorite = !items.isEmpty && items.allSatisfy(\.favorite)
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text("已选择 \(store.selection.count) 项资料").font(.title3.weight(.semibold))
            Text("可以批量收藏、整理归类，或删除资料库中的副本。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
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
                Button(role: .destructive) { store.requestTrashSelection() } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .controlSize(.large)
            .disabled(store.isBatchUpdating || store.isDeleting)
            Text("删除会把资料移到回收站并保留 \(LibraryRetention.trashDays) 天，原始文件仍保留在原位置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct LinkedFilePreviewView: View {
    let file: LinkedFilePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(file.title ?? file.url.lastPathComponent).font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(file.isManaged ? "资料库副本 · 只读预览" : "本地文件预览 · 尚未导入资料库").font(.caption).foregroundStyle(.secondary)
            if let position = file.position {
                SourceTextPreview(url: file.url, position: position)
                    .frame(minWidth: 780, minHeight: 520)
                    .id(file.id)
            } else {
                SystemPreview(url: file.url).frame(minWidth: 680, minHeight: 480)
            }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }.padding(20)
    }
}
