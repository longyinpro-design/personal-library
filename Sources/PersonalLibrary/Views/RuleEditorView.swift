import LibraryCore
import SwiftUI

/// Edits the deterministic import rules. Kept as a sheet so settings stay a
/// summary; rules are edited as a list because order is the priority.
struct RuleEditorView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [LibraryRule] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入规则").font(.headline)
                Text("文件名包含匹配词时，导入后自动归入目录并打上标签。从上往下匹配，第一条生效；目录不存在会新建。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if rules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.checkmark").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("还没有规则").foregroundStyle(.secondary)
                    Text("例如匹配词「合同」→ 目录「合同」+ 标签「待归档」。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($rules) { $rule in
                            RuleRow(rule: $rule) {
                                rules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button {
                    rules.append(LibraryRule(match: ""))
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.saveRules(rules)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .onAppear { rules = store.rules }
    }
}

private struct RuleRow: View {
    @Binding var rule: LibraryRule
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Toggle("", isOn: $rule.isEnabled)
                    .labelsHidden()
                    .help("停用后这条规则不参与匹配")
                TextField("匹配词，如 合同", text: $rule.match)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除这条规则")
            }
            HStack(spacing: 8) {
                TextField("归入目录（可留空）", text: Binding(
                    get: { rule.collection ?? "" },
                    set: { rule.collection = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                TextField("标签，逗号分隔", text: Binding(
                    get: { rule.tags.joined(separator: "，") },
                    set: { rule.tags = Self.parse($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .opacity(rule.isEnabled ? 1 : 0.55)
    }

    /// Accepts the separators people actually type; empty pieces are dropped.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、;； ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
