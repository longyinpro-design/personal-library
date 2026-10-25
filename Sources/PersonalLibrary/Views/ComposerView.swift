import SwiftUI
import LibraryCore

struct ComposerView: View {
    @ObservedObject var store: LibraryStore
    let initial: NoteDraft
    @ObservedObject private var draft: NoteDraft
    @ViewState<String?> private var failure: String?
    @ViewState<Bool> private var confirmDiscard = false
    @FocusState private var titleFocused: Bool

    init(store: LibraryStore, initial: NoteDraft) {
        self.store = store; self.initial = initial
        self.draft = initial
    }

    private var changed: Bool { draft.hasChanges }
    private var saving: Bool { store.isSavingNote }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(initial.itemID == nil ? "新建\(draft.kind.label)" : "编辑\(draft.kind.label)", systemImage: draft.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("保存在本机").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            TextField("给这个想法起个名字", text: $draft.title)
                .textFieldStyle(.plain).font(.system(size: 25, weight: .semibold)).focused($titleFocused)
                .accessibilityLabel("标题").padding(24)
                .disabled(saving)
            TextEditor(text: $draft.body).font(.system(size: 14)).lineSpacing(6)
                .scrollContentBackground(.hidden).padding(.horizontal, 20).accessibilityLabel("正文")
                .disabled(saving)
            if let failure { Text(failure).foregroundStyle(.red).font(.system(size: 12)).padding(.horizontal, 24) }
            Divider()
            HStack {
                Text("\(draft.body.count) 字  ·  支持纯文本 / Markdown").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { if changed { confirmDiscard = true } else { store.draft = nil } }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "正在保存…" : "保存") {
                    failure = nil
                    Task {
                        do { try await store.save(draft) }
                        catch { failure = error.localizedDescription }
                    }
                }.keyboardShortcut("s").buttonStyle(.borderedProminent)
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20)
        }.frame(width: 690, height: 570)
        .interactiveDismissDisabled(changed || saving)
        .onAppear { titleFocused = true }
        .confirmationDialog("放弃未保存的内容？", isPresented: $confirmDiscard) {
            Button("放弃修改", role: .destructive) { store.draft = nil }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("关闭后，这次修改不会保存。") }
    }
}

struct CollectionSheet: View {
    @ObservedObject var store: LibraryStore
    @ViewState<String> private var name = ""
    @ViewState<String?> private var failure: String?
    @ViewState<Bool> private var saving = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(store.newCollectionParentID == nil ? "新建目录" : "新建子目录", systemImage: "folder.badge.plus")
                .font(.title3.weight(.semibold))
            Text(store.newCollectionParentID.map { "会放在「\(store.collectionPath($0))」下面。" }
                 ?? "按项目或主题整理资料，例如「工作项目」「生活记录」。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("目录名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            if let failure { Text(failure).foregroundStyle(.red).font(.system(size: 12)) }
            HStack {
                Spacer()
                Button("取消") {
                    store.showNewCollection = false
                    store.newCollectionParentID = nil
                }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("创建") {
                    saving = true
                    Task {
                        do { try await store.createCollection(name) }
                        catch { failure = error.localizedDescription }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 430).onAppear { focused = true }
    }
}
