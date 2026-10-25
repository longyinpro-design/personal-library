import LibraryCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    private var selection: Binding<LibraryScope?> {
        Binding(get: { store.scope }, set: { if let target = $0 { store.navigate(target) } })
    }

    private enum RenameTarget: Equatable {
        case tag(LibraryTag)
        case collection(LibraryCollection)
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
                ForEach(visibleCollections) { row in
                    collectionRow(row)
                }
                Button { store.beginNewCollection() } label: {
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
        .alert(renameTitle, isPresented: Binding(get: { renaming != nil },
                                                 set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("重命名") { commitRename() }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text(renameMessage)
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

    private var renameTitle: String {
        switch renaming {
        case .tag: return "重命名标签"
        case .collection: return "重命名目录"
        case nil: return "重命名"
        }
    }

    private var renameMessage: String {
        switch renaming {
        case .tag: return "资料和标签的关联会一起改名。"
        case .collection: return "只改名字，里面的资料和子目录都留在原处。"
        case nil: return ""
        }
    }

    private func commitRename() {
        switch renaming {
        case .tag(let tag):
            store.renameTag(tag, to: renameText)
        case .collection(let collection):
            store.renameCollection(collection, to: renameText)
        case nil:
            break
        }
        renaming = nil
    }

    // MARK: - Folders

    /// Depth-first folders with collapsed subtrees left out.
    private var visibleCollections: [LibraryStore.CollectionRow] {
        var rows: [LibraryStore.CollectionRow] = []
        func walk(_ parentID: String?, depth: Int) {
            for row in store.collectionRows where row.parentID == parentID {
                rows.append(LibraryStore.CollectionRow(collection: row.collection, depth: depth))
                if store.expandedCollections.contains(row.id) {
                    walk(row.id, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 0)
        return rows
    }

    private func childCount(of id: String) -> Int {
        store.snapshot.collections.filter { $0.parentID == id }.count
    }

    private func collectionRow(_ row: LibraryStore.CollectionRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(store.expandedCollections.contains(row.id) ? 90 : 0))
                .foregroundStyle(.secondary)
                .opacity(childCount(of: row.id) > 0 ? 1 : 0)
                .frame(width: 10)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleCollection(row.id) }
            Label(row.name, systemImage: "folder")
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .tag(LibraryScope.collection(row.collection.id))
        .contextMenu {
            Button("新建子目录…") { store.beginNewCollection(in: row.collection.id) }
                .disabled(row.depth + 1 >= 5)
            Button("重命名…") {
                renameText = row.name
                renaming = .collection(row.collection)
            }
            Menu("移到…") {
                Button("顶层") { store.moveCollection(row.collection, to: nil) }
                    .disabled(row.parentID == nil)
                Divider()
                ForEach(movableTargets(in: store, excluding: row.collection)) { target in
                    Button(String(repeating: "    ", count: target.depth) + target.name) {
                        store.moveCollection(row.collection, to: target.id)
                    }
                }
            }
            Divider()
            Button("删除目录", role: .destructive) { store.deleteCollection(row.collection) }
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
                renaming = .tag(tag)
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
