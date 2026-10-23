import SwiftUI
import LibraryCore

// SwiftUI also re-exports DeveloperToolsSupport.LibraryItem.
typealias LibraryItem = LibraryCore.LibraryItem
// macOS 27 SDK exports a same-named macro; select the stable property-wrapper type.
typealias ViewState<Value> = SwiftUI.State<Value>

struct FileBadge: View {
    let item: LibraryItem
    var large = false
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: large ? 38 : 25, weight: .light))
                .symbolRenderingMode(.hierarchical)
            Text(item.fileExtension.isEmpty ? "FILE" : String(item.fileExtension.prefix(6)))
                .font(.system(size: large ? 10 : 8, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: large ? 64 : 34, height: large ? 76 : 48)
        .accessibilityHidden(true)
    }
}

struct EmptyLibraryView: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
