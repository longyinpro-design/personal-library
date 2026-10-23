import AppKit
import LibraryCore
import Quartz
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: LibraryStore
    @ViewState<Bool> private var showSystemPreview = false
    var body: some View {
        VStack(spacing: 0) {
            if let item = store.selectedItem, store.scope != .history {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header(item).id(MarkdownScrollTarget.top)
                            if let note = item.extractionNote {
                                Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                            }
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
                            if !item.isEditable && (showSystemPreview || item.kind == .image || item.fileExtension == "PDF") {
                                if let url = try? store.fileURL(item) {
                                    SystemPreview(url: url).frame(minHeight: 460).id(item.id)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Label("文件不在原位置，请恢复备份或重新导入。", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.secondary).font(.system(size: 12))
                                }
                            } else if !item.text.isEmpty {
                                if item.usesMarkdown {
                                    MarkdownReader(source: item.text,
                                                   imageContext: .init(itemID: item.id, basePath: item.imageBasePath, revision: store.imageDirectoryRevision, attachments: item.imageAttachments),
                                                   imageIssues: item.imageAttachmentIssues,
                                                   isCopyingImages: store.isCopyingImages,
                                                   chooseImageDirectory: { store.chooseImageDirectory(item) },
                                                   copyImages: { store.copyImages(item) },
                                                   readingRequest: store.readingRequest,
                                                   followLink: { store.followMarkdownLink($0, from: item) },
                                                   scrollTo: { proxy.scrollTo($0, anchor: .top) },
                                                   reportError: { store.errorMessage = $0 })
                                } else {
                                    BodyTextView(text: item.text)
                                }
                            } else {
                                EmptyLibraryView(title: "使用系统查看完整内容", message: "点击「预览文件」或「打开文件」。", symbol: "doc.viewfinder")
                                    .frame(minHeight: 260)
                            }
                        }.padding(28)
                    }
                }.id(item.id)
            } else {
                EmptyLibraryView(title: "每一份资料，都触手可及", message: "选择一份文件或笔记，\n在这里查看内容与整理归属。", symbol: "doc.text.magnifyingglass")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.goBack() } label: { Label("返回上一份资料", systemImage: "chevron.left") }
                    .disabled(store.backHistory.isEmpty).help("返回 · ⌘[")
                    .keyboardShortcut("[", modifiers: .command)
                Button { store.goForward() } label: { Label("前进", systemImage: "chevron.right") }
                    .disabled(store.forwardHistory.isEmpty).help("前进 · ⌘]")
                    .keyboardShortcut("]", modifiers: .command)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let item = store.selectedItem, store.scope != .history {
                    Button { store.favorite(item) } label: {
                        Label(item.favorite ? "取消收藏" : "收藏", systemImage: item.favorite ? "star.fill" : "star")
                    }.help(item.favorite ? "取消收藏" : "收藏")
                    Menu {
                        if item.isEditable {
                            Button { store.edit(item) } label: { Label("编辑", systemImage: "square.and.pencil") }
                            Button { store.export(item) } label: { Label("导出为 Markdown…", systemImage: "square.and.arrow.up") }
                        } else {
                            Button { store.open(item) } label: { Label("打开文件", systemImage: "arrow.up.forward.app") }
                            Button { store.reveal(item) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                        }
                    } label: { Label("资料操作", systemImage: "ellipsis") }
                    .help("资料操作")
                }
            }
        }
        .onChange(of: store.selectedID) { _, _ in showSystemPreview = false }
    }

    private func header(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            FileBadge(item: item, large: true)
            Text(item.title).font(.system(size: 24, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("\(item.kind.label)  ·  \(item.updatedAt.formatted(date: .long, time: .omitted))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if item.isEditable {
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
