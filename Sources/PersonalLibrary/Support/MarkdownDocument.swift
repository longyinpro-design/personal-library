import LibraryCore
import Combine
import Foundation
import MarkdownUI

/// Keep parsing independent of search updates and publish only the current document.
@MainActor
final class MarkdownDocument: ObservableObject {
    @Published private(set) var content: MarkdownContent?
    @Published private(set) var sections: [MarkdownContent] = []
    @Published private(set) var anchors: [String: Int] = [:]
    @Published private(set) var failure: String?
    private var source: String?
    private var generation = 0

    func load(_ text: String) async {
        guard !Task.isCancelled else { return }
        if source == text, content != nil { return }
        source = text
        generation += 1
        let request = generation
        content = nil
        sections = []; anchors = [:]; failure = nil
        let worker = Task.detached(priority: .userInitiated) {
            let parsed = try MarkdownStructure.parse(text)
            return (parsed.sections.map { MarkdownContent($0.markdown) }, parsed.anchors)
        }
        do {
            let parsed = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, generation == request else { return }
            sections = parsed.0; anchors = parsed.1
            content = MarkdownContent { for section in parsed.0 { section } }
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            failure = error.localizedDescription
        }
    }
}

enum MarkdownLinkPolicy {
    static func opensInBrowser(_ url: URL) -> Bool {
        MarkdownLinks.opensInBrowser(url)
    }
}
