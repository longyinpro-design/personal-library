import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
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
        }
        .listStyle(.sidebar)
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

    private func row(_ title: String, symbol: String, scope: LibraryScope, count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            if let count, count > 0 { Text(count, format: .number).font(.caption).foregroundStyle(.secondary) }
        }
        .tag(scope)
    }
}
