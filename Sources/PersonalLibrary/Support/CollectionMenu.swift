import LibraryCore
import SwiftUI

/// Folders as menu items. A flat menu is still what macOS gives us, so nesting
/// shows up as indentation and the full path is in the tooltip.
@MainActor
@ViewBuilder
func collectionMenuButtons(_ store: LibraryStore,
                           action: @escaping (String) -> Void) -> some View {
    ForEach(store.collectionRows) { row in
        Button(String(repeating: "    ", count: row.depth) + row.name) { action(row.id) }
            .help(store.collectionPath(row.id))
    }
}

/// Folders that may become the new parent of `collection`: everything except
/// itself and its own descendants.
@MainActor
func movableTargets(in store: LibraryStore, excluding collection: LibraryCollection) -> [LibraryStore.CollectionRow] {
    var blocked: Set<String> = [collection.id]
    var frontier = [collection.id]
    while !frontier.isEmpty {
        let children = store.snapshot.collections.filter { parent in frontier.contains(parent.parentID ?? "") }.map(\.id)
        blocked.formUnion(children)
        frontier = children
    }
    return store.collectionRows.filter { !blocked.contains($0.id) }
}
