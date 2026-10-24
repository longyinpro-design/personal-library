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

enum MarkdownScrollTarget: Hashable, Sendable {
    case top
    case section(Int)
    case bodyChunk(Int)
}

/// A coarse, lazy-layout-safe reading position. Markdown is remembered by
/// section and plain text by chunk; pixel offsets are not stable while
/// `LazyVStack` is still materializing.
enum ReadingAnchor: Hashable {
    case markdownSection(Int)
    case bodyChunk(Int)
}
