import SwiftUI
import LibraryCore

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
    @State private var renaming: LibraryTag?
    @State private var renameText = ""
    private var selection: Binding<LibraryScope?> {
        Binding(get: { store.scope }, set: { if let target = $0 { store.navigate(target) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("资料库") {
                row("全部资料", symbol: "square.grid.2x2", scope: .all)
                row("最近添加", symbol: "clock", scope: .recent)
                row("待整理", symbol: "tray", scope: .inbox, count: store.inboxCount)
                row("已收藏", symbol: "star", scope: .favorites)
            }
            Section("我的记录") {
                row("笔记", symbol: "note.text", scope: .notes)
                row("随笔", symbol: "text.bubble", scope: .thoughts)
                row("整理记录", symbol: "clock.arrow.circlepath", scope: .history)
            }
            Section("我的目录") {
                ForEach(store.snapshot.collections) { collection in
                    row(collection.name, symbol: "folder", scope: .collection(collection.id))
                }
                Button { store.showNewCollection = true } label: {
                    Label("新建目录…", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).disabled(!store.ready)
            }
            Section("标签") {
                let tags = store.snapshot.tags.filter { $0.count > 0 }
                ForEach(tags) { tag in
                    tagRow(tag)
                }
                if tags.isEmpty {
                    Text("给资料打标签后出现在这里").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                row("回收站", symbol: "trash", scope: .trash, count: store.trashedCount)
            }
        }
        .listStyle(.sidebar)
        .alert("重命名标签", isPresented: Binding(get: { renaming != nil },
                                                 set: { if !$0 { renaming = nil } })) {
            TextField("标签名称", text: $renameText)
            Button("重命名") {
                if let tag = renaming { store.renameTag(tag, to: renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("资料和标签的关联会一起改名。")
        }
        .navigationTitle("个人资料库")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label("本地资料库", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
            }.padding(16)
        }
    }

    private func tagRow(_ tag: LibraryTag) -> some View {
        HStack {
            Label("#" + tag.name, systemImage: "number")
            Spacer(minLength: 0)
            Text(tag.count, format: .number).font(.caption).foregroundStyle(.secondary)
        }
        .tag(LibraryScope.tag(tag.name))
        .contextMenu {
            Button("重命名…") {
                renameText = tag.name
                renaming = tag
            }
            Button("删除标签", role: .destructive) { store.deleteTag(tag) }
        }
    }

    private func row(_ title: String, symbol: String, scope: LibraryScope, count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            if let count, count > 0 { Text(count, format: .number).font(.caption).foregroundStyle(.secondary) }
        }
        .tag(scope)
    }
}
