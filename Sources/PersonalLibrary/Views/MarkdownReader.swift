import LibraryCore
import AppKit
import MarkdownUI
import SwiftUI

struct MarkdownReader: View {
    let source: String
    let imageContext: MarkdownImageContext
    let imageIssues: [String]
    let isCopyingImages: Bool
    let chooseImageDirectory: () -> Void
    let copyImages: () -> Void
    let readingRequest: ReadingRequest?
    let followLink: (URL) -> Void
    let scrollTo: (MarkdownScrollTarget) -> Void
    let reportError: (String) -> Void
    @StateObject private var document = MarkdownDocument()
    @ViewState<Bool> private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Picker("Markdown 显示方式", selection: $showSource) {
                    Text("阅读").tag(false)
                    Text("原文").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Button("保存配图", action: copyImages)
                    .controlSize(.small)
                    .help("把尚未保存的本地配图复制进资料库")
                    .disabled(isCopyingImages)
                Button("图片目录…", action: chooseImageDirectory)
                    .disabled(isCopyingImages)
                    .controlSize(.small)
                    .help(imageContext.basePath ?? "为相对图片选择原文所在文件夹")
            }

            if !imageContext.attachments.isEmpty || !imageIssues.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: imageIssues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    Text("已保存 \(imageContext.attachments.count) 个配图引用" + (imageIssues.isEmpty ? "，可随资料库一起备份" : "；\(imageIssues.count) 个未能保存或更新"))
                }
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.disabled)
                if !imageIssues.isEmpty {
                    DisclosureGroup("未保存或未更新的配图") {
                        Text(imageIssues.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            if showSource {
                BodyTextView(text: source, monospaced: true)
            } else if document.content != nil {
                // Lazy sections keep document switching fast; ScrollViewReader still
                // instantiates the target section when an anchor link is followed.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.sections.indices, id: \.self) { index in
                        Markdown(document.sections[index])
                            .padding(.top, index == 0 ? 0 : 24)
                            .id(MarkdownScrollTarget.section(index))
                    }
                }
                    .markdownTheme(.library)
                    .markdownImageProvider(LocalBlockImageProvider(context: imageContext))
                    .markdownInlineImageProvider(LocalInlineImageProvider(context: imageContext))
                    .id(imageContext)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if MarkdownLinkPolicy.opensInBrowser(url) { return .systemAction }
                        followLink(url)
                        return .handled
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure = document.failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView("正在排版…").controlSize(.small)
            }
        }
        .frame(maxWidth: 840, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) { await document.load(source) }
        .task(id: JumpKey(request: readingRequest, ready: document.content != nil)) {
            guard let request = readingRequest, request.itemID == imageContext.itemID,
                  document.content != nil else { return }
            showSource = false
            // Let the parsed section views enter the scroll hierarchy before scrolling.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let fragment = request.fragment, !fragment.isEmpty {
                guard let index = document.anchors[fragment] ?? document.anchors[fragment.lowercased()] else {
                    reportError("此文档中没有找到标题「\(fragment)」。目标文档已打开，可在「原文」中核对链接。")
                    return
                }
                scrollTo(.section(index))
                // Lazy sections are created on demand; a request handled in the
                // same update cycle can run before the target section exists.
                // Retry once after SwiftUI has laid the stack out.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                scrollTo(.section(index))
            } else { scrollTo(.top) }
        }
    }

    private struct JumpKey: Equatable {
        let request: ReadingRequest?
        let ready: Bool

    }
}

struct LocalBlockImageProvider: ImageProvider {
    let context: MarkdownImageContext
    func makeImage(url: URL?) -> some View {
        LocalMarkdownImageView(url: url, context: context)
            .textSelection(.disabled) // Avoid SwiftUI's image-alt/selectable-text AX cycle.
    }
}

struct LocalInlineImageProvider: InlineImageProvider {
    let context: MarkdownImageContext
    func image(with url: URL, label: String) async throws -> Image {
        do {
            let image = try await LocalMarkdownImages.shared.load(url, context: context)
            let scale = min(1, min(320 / Double(image.width), 180 / Double(image.height)))
            return Image(nsImage: NSImage(cgImage: image, size: CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)))
        } catch {
            // MarkdownUI drops all inline images if any one provider throws.
            let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: "\(label)：\(error.localizedDescription)") ?? NSImage(size: CGSize(width: 16, height: 16))
            return Image(nsImage: symbol)
        }
    }
}

private struct LocalMarkdownImageView: View {
    let url: URL?
    let context: MarkdownImageContext
    @ViewState<CGImage?> private var image = nil
    @ViewState<String?> private var failure = nil

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: CGFloat(image.width), alignment: .leading)
            } else if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView("正在加载图片…").controlSize(.small)
            }
        }
        .task(id: ImageRequest(url: url, context: context)) {
            image = nil; failure = nil
            do {
                guard let url else { throw MarkdownImageError.invalidPath }
                let decoded = try await LocalMarkdownImages.shared.load(url, context: context)
                try Task.checkCancellation()
                image = decoded
            } catch is CancellationError {
                // A new document or image request owns this view now.
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private struct ImageRequest: Hashable {
        let url: URL?
        let context: MarkdownImageContext
    }
}

private extension Theme {
    static let library = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(14)
        }
        .link { ForegroundColor(.accentColor) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.primary.opacity(0.06))
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle { ForegroundColor(.secondary) }
                .padding(.leading, 16)
                .padding(.vertical, 6)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.35)).frame(width: 3)
                }
                .markdownMargin(top: 8, bottom: 16)
        }
        .codeBlock { configuration in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(configuration.language ?? "代码").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration.content, forType: .string)
                    } label: { Label("复制", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("复制代码")
                }.padding(.horizontal, 14).padding(.vertical, 9)
                Divider()
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            BackgroundColor(nil)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .relativeLineSpacing(.em(0.2))
                        .padding(14)
                }
            }
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)) }
            .markdownMargin(top: 0, bottom: 18)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: false)
                    .markdownTableBorderStyle(.init(color: .primary.opacity(0.14)))
                    .markdownTableBackgroundStyle(.alternatingRows(.clear, .primary.opacity(0.035)))
            }
            .markdownMargin(top: 4, bottom: 18)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    BackgroundColor(nil)
                }
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
        }
}
