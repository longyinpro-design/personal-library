import AppKit
import LibraryCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: LibraryStore
    @State private var selectingBackup = false

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
                LabeledContent("最近备份") {
                    if let newest = store.backups.first {
                        Text("\(newest.date.formatted(date: .abbreviated, time: .shortened))（\(ByteCountFormatter.string(fromByteCount: Int64(newest.byteCount), countStyle: .file))）")
                    } else {
                        Text("尚未备份")
                    }
                }
                LabeledContent("备份份数", value: "\(store.backups.count) 份，保留最近 \(LibraryBackupStore.retention) 份")
                HStack(spacing: 10) {
                    Button(store.isBackingUp ? "正在备份…" : "立即备份") { Task { await store.createBackup() } }
                        .disabled(store.isBackingUp || !store.ready)
                    Button("打开备份目录") { store.revealBackups() }
                    Button("从备份恢复…") { selectingBackup = true }
                        .disabled(!store.ready)
                }
                if store.hasPendingRestore {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("下次启动时恢复「\(store.pendingRestoreName)」，当前资料库会先另存为 \(LibraryBackupStore.safetyCopyName)。")
                            .foregroundStyle(.orange)
                        Button("取消恢复") { store.cancelPendingRestore() }
                    }.padding(.vertical, 4)
                }
                Text("备份由 SQLite 自身写出（VACUUM INTO），包含笔记、正文、标签与索引。导入到 Files/ 的文件副本不在备份内，原文件仍在原位置。恢复只替换数据库，不会删除这些副本。")
            }
            Section("第一版支持") {
                Text("PDF 文字层、Word、RTF 与文本正文搜索；图片与其他格式支持文件名搜索和系统预览。暂不包含 OCR、云同步或 AI 分类。")
                Text("每个文件最大 200 MB，最多提取 200 万个字符用于搜索。搜索覆盖当前左侧分类，可选择「全部资料」搜索整个资料库。")
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 12))
        .frame(width: 570, height: 540)
        .fileImporter(isPresented: $selectingBackup, allowedContentTypes: [.database, .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result { store.errorMessage = error.localizedDescription }
                return
            }
            store.prepareRestore(from: url)
        }
    }
}
