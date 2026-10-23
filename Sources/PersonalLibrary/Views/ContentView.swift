import SwiftUI
import LibraryCore

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @ViewState<Bool> private var dropTarget = false
    @ViewState<Bool> private var searchPresented = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        if #available(macOS 15.0, *) {
            library.searchFocused($searchFocused)
        } else {
            library
        }
    }

    private var library: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } content: {
            ItemListView(store: store)
                .navigationSplitViewColumnWidth(min: 330, ideal: 410, max: 560)
                .navigationTitle(store.scopeTitle)
                .navigationSubtitle(store.scope == .history ? "最近 200 次操作" : store.isSearching ? "正在搜索…" : "\(store.displayedItems.count) 项资料")
        } detail: {
            DetailView(store: store)
                .frame(minWidth: 340)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $store.query, isPresented: $searchPresented, placement: .toolbar,
                    prompt: store.scope == .history ? "搜索全部资料" : "搜索\(store.scopeTitle)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.chooseFiles() } label: { Label("导入文件", systemImage: "tray.and.arrow.down") }
                    .help("导入文件 · ⌘O").disabled(!store.ready || store.isImporting || store.draft != nil)
                Button { store.newNote() } label: { Label("新建笔记", systemImage: "square.and.pencil") }
                    .help("新建笔记 · ⌘N").disabled(!canCreate)
                Menu {
                    Button { store.newNote(kind: .thought) } label: { Label("写随笔", systemImage: "text.bubble") }
                    Button { store.showNewCollection = true } label: { Label("新建目录…", systemImage: "folder.badge.plus") }
                } label: { Label("更多新建", systemImage: "plus") }
                    .disabled(!canCreate)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .overlay(Label("松开以导入资料", systemImage: "tray.and.arrow.down")
                        .font(.title2).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard store.ready, !store.isImporting else { return false }
            store.importFiles(urls); return true
        } isTargeted: { dropTarget = $0 }
        .sheet(item: $store.linkedFilePreview) { file in LinkedFilePreviewView(file: file) }
        .sheet(item: $store.draft) { draft in ComposerView(store: store, initial: draft) }
        .sheet(isPresented: $store.showNewCollection) { CollectionSheet(store: store) }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("删除所选资料？",
                            isPresented: Binding(get: { !store.pendingDeletion.isEmpty },
                                                 set: { if !$0 { store.cancelDelete() } }),
                            titleVisibility: .visible) {
            Button("删除 \(store.pendingDeletion.count) 项", role: .destructive) {
                let ids = store.pendingDeletion
                Task { await store.confirmDelete(ids) }
            }
            Button("取消", role: .cancel) { store.cancelDelete() }
        } message: {
            Text("只删除资料库内的副本与配图，原始文件仍保留在原位置。此操作无法撤销。")
        }
        .onChange(of: store.focusSearch) { _, _ in
            searchPresented = true
            searchFocused = true
        }
    }

    private var canCreate: Bool { store.ready && !store.isImporting && store.draft == nil }
}
