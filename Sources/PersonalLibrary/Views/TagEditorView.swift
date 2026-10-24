import SwiftUI
import LibraryCore

/// Applies one tag list to a whole selection, so a checkbox means "this tag is
/// on every selected item" rather than per-item state.
struct TagEditorView: View {
    @ObservedObject var store: LibraryStore
    let request: LibraryStore.TagEditorRequest

    @State private var chosen: Set<String> = []
    @State private var newName = ""
    @State private var seeded = false

    private var items: [LibraryItem] { store.tagEditorItems }

    /// Tag names in the library plus whatever this sheet has typed, keyed by a
    /// case-insensitive form because the database stores names with NOCASE.
    private var displayNames: [String: String] {
        var names: [String: String] = [:]
        for tag in store.snapshot.tags { names[tag.name.lowercased()] = tag.name }
        for item in items { for name in item.tags { names[name.lowercased()] = name } }
        for name in chosen { names[name.lowercased()] = names[name.lowercased()] ?? name }
        return names
    }

    private var names: [String] { displayNames.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var trimmedNewName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text("勾选的标签会应用到所选的每一项。").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            List {
                if names.isEmpty {
                    Text("还没有标签，在下面输入名称新建。")
                        .foregroundStyle(.secondary)
                }
                ForEach(names, id: \.self) { name in
                    Toggle(isOn: binding(for: name)) {
                        Label("#" + name, systemImage: "number")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                TextField("新标签名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewTag)
                Button("添加", action: addNewTag)
                    .disabled(trimmedNewName.isEmpty)
            }
            .padding(12)

            Divider()

            HStack {
                Button("取消", role: .cancel) { store.endTagEditing() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    store.applyTags(names.filter(chosen.contains), to: request.itemIDs)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 380, height: 460)
        .onAppear(perform: seed)
    }

    private var title: String {
        guard let first = items.first else { return "设置标签" }
        return items.count == 1 ? "为「\(first.title)」设置标签" : "为 \(items.count) 项资料设置标签"
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(name) },
            set: { isOn in
                if isOn { chosen.insert(name) } else { chosen.remove(name) }
            }
        )
    }

    private func addNewTag() {
        let name = trimmedNewName
        guard !name.isEmpty else { return }
        // Reuse the library's spelling when the name already exists.
        let display = displayNames[name.lowercased()] ?? String(name.prefix(32))
        chosen.insert(display)
        newName = ""
    }

    /// Starts from the tags every selected item already shares.
    private func seed() {
        guard !seeded, let first = items.first else { return }
        seeded = true
        var common = Set(first.tags.map { $0.lowercased() })
        for item in items.dropFirst() {
            common.formIntersection(item.tags.map { $0.lowercased() })
        }
        chosen = Set(common.compactMap { displayNames[$0] })
    }
}
