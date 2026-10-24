import Foundation

/// Watches one folder for new or changed entries. A directory file descriptor
/// with a dispatch source is enough for a single level; events are collapsed
/// into one callback after a short pause so a file copied in several chunks is
/// imported once instead of once per chunk.
final class InboxWatcher {
    static let debounce: TimeInterval = 0.8

    private let queue = DispatchQueue(label: "com.longyinpro.personal-library.inbox")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private(set) var folder: URL?
    /// Called on the main queue after the folder settles.
    var onChange: (() -> Void)?

    func start(watching folder: URL) {
        stop()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        self.folder = folder
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        folder = nil
    }

    deinit {
        // Only cancel here; the cancel handler owns closing the descriptor.
        pending?.cancel()
        source?.cancel()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange?() }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + InboxWatcher.debounce, execute: item)
    }
}
