import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

/// One item as it should appear in Spotlight. Only the fields someone would
/// search by: the full body stays in the library.
public struct SpotlightDocument: Sendable, Equatable {
    public var id: String
    public var title: String
    public var summary: String
    public var keywords: [String]

    public init(id: String, title: String, summary: String, keywords: [String]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.keywords = keywords
    }
}

/// Where the app reports searchable items. Kept small so tests can record calls
/// without a Spotlight service.
public protocol SpotlightSink: Sendable {
    func index(_ documents: [SpotlightDocument]) async
    func remove(identifiers: [String]) async
    func removeAll() async
}

/// The real sink: CoreSpotlight's default index. Failures are logged and
/// swallowed, because a missing index must never block library work.
public struct SystemSpotlightSink: SpotlightSink {
    public static let domain = "com.longyinpro.personal-library.items"
    private static let log = Logger(subsystem: "com.longyinpro.personal-library", category: "spotlight")

    public init() {}

    /// Only a packaged app has a Spotlight client; a test runner would log XPC
    /// noise for every call.
    private static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public func index(_ documents: [SpotlightDocument]) async {
        guard Self.isAvailable, !documents.isEmpty else { return }
        do {
            try await CSSearchableIndex.default().indexSearchableItems(documents.map(Self.searchableItem))
        } catch { Self.log.error("上报 Spotlight 失败：\(error.localizedDescription, privacy: .public)") }
    }

    public func remove(identifiers: [String]) async {
        guard Self.isAvailable, !identifiers.isEmpty else { return }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
        } catch { Self.log.error("从 Spotlight 移除失败：\(error.localizedDescription, privacy: .public)") }
    }

    public func removeAll() async {
        guard Self.isAvailable else { return }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        } catch { Self.log.error("清空 Spotlight 索引失败：\(error.localizedDescription, privacy: .public)") }
    }

    static func searchableItem(_ document: SpotlightDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = document.title
        attributes.contentDescription = document.summary
        attributes.textContent = document.summary
        attributes.keywords = document.keywords
        return CSSearchableItem(uniqueIdentifier: document.id, domainIdentifier: domain, attributeSet: attributes)
    }
}
