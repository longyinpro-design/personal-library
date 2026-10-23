import Foundation
import LibraryCore

struct ReadingRequest: Equatable {
    let id = UUID()
    let itemID: String
    let fragment: String?
}

struct ReadingLocation {
    let itemID: String
    let fragment: String?
    let scope: LibraryScope
    let query: String
    let kind: ItemKind?
}

struct LinkedFilePreview: Identifiable {
    let id = UUID()
    let url: URL
    var position: SourcePosition? = nil
    var title: String? = nil
    var isManaged = false
}

enum MarkdownScrollTarget: Hashable {
    case top
    case section(Int)
}
