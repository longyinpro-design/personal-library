import Foundation

/// How the list is ordered. Applied over whatever is already in memory: the
/// snapshot for a plain list, the search hits for a query.
public enum LibrarySortField: String, CaseIterable, Sendable, Identifiable {
    case updated, created, title, size

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .updated: "更新时间"
        case .created: "创建时间"
        case .title: "名称"
        case .size: "大小"
        }
    }
}

/// Ordering and filtering for the item list. Lives in the store, so it survives
/// switching folders and scopes for the rest of the run.
public struct LibraryListOptions: Sendable, Equatable {
    public var sortField: LibrarySortField = .updated
    public var ascending = false
    /// Compares against the item's creation date, inclusive on both ends.
    public var startDate: Date?
    public var endDate: Date?
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var onlyWithBody = false
    public var onlyWithImages = false
    public var onlyWithLinks = false

    public init() {}

    public var hasFilters: Bool {
        startDate != nil || endDate != nil || minBytes != nil || maxBytes != nil
            || onlyWithBody || onlyWithImages || onlyWithLinks
    }

    public var filterCount: Int {
        var count = 0
        if startDate != nil || endDate != nil { count += 1 }
        if minBytes != nil || maxBytes != nil { count += 1 }
        if onlyWithBody { count += 1 }
        if onlyWithImages { count += 1 }
        if onlyWithLinks { count += 1 }
        return count
    }

    public func matches(_ item: LibraryItem) -> Bool {
        if let startDate, item.createdAt < startDate { return false }
        if let endDate, item.createdAt > endDate { return false }
        if let minBytes, item.byteCount < minBytes { return false }
        if let maxBytes, item.byteCount > maxBytes { return false }
        if onlyWithBody && !item.hasBody { return false }
        if onlyWithImages && item.imageAttachments.isEmpty { return false }
        if onlyWithLinks && !item.hasLinks { return false }
        return true
    }

    /// Ties fall back to the id so the same options always produce the same order.
    public func sorted(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortField {
            case .updated:
                order = lhs.updatedAt == rhs.updatedAt ? .orderedSame : (lhs.updatedAt < rhs.updatedAt ? .orderedAscending : .orderedDescending)
            case .created:
                order = lhs.createdAt == rhs.createdAt ? .orderedSame : (lhs.createdAt < rhs.createdAt ? .orderedAscending : .orderedDescending)
            case .title:
                order = lhs.title.localizedStandardCompare(rhs.title)
            case .size:
                order = lhs.byteCount == rhs.byteCount ? .orderedSame : (lhs.byteCount < rhs.byteCount ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return ascending ? lhs.id < rhs.id : lhs.id > rhs.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
