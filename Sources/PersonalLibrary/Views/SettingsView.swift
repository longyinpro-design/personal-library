import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        Form {
            Section("本地资料库") {
                LabeledContent("资料数量", value: "\(store.snapshot.items.count) 项")
                LabeledContent("内容大小", value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                VStack(alignment: .leading, spacing: 9) {
                    Text("存储位置").font(.headline)
                    Text(store.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(store.root) }
                }.padding(.vertical, 7)
            }
            Section("资料与备份") {
                Text("导入会将文件复制到资料库，原文件保持不变。目录只用于资料库内分类，不会移动原文件。")
                Text("备份时先退出 App，再复制整个 PersonalLibrary 文件夹。笔记保存在 SQLite 数据库中，也可单独导出为 Markdown。")
            }
            Section("第一版支持") {
                Text("PDF 文字层、Word、RTF 与文本正文搜索；图片与其他格式支持文件名搜索和系统预览。暂不包含 OCR、云同步或 AI 分类。")
                Text("每个文件最大 200 MB，最多提取 200 万个字符用于搜索。搜索覆盖当前左侧分类，可选择「全部资料」搜索整个资料库。")
            }
        }.formStyle(.grouped).font(.system(size: 12)).frame(width: 570, height: 540)
    }
}
