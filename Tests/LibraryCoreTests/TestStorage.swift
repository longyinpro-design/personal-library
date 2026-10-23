import Foundation

// Foundation's temporaryDirectory can ignore the storage guard's TMPDIR on macOS.
// Use the explicit build root for test-created files, with the system default on
// machines that do not run this project's storage guard.
let testTemporaryDirectory: URL = {
    let base = ProcessInfo.processInfo.environment["AGENT_BUILD_ROOT"] ?? NSTemporaryDirectory()
    let directory = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("test-data", isDirectory: true).resolvingSymlinksInPath()
    print("Test artifacts: \(directory.path)")
    return directory
}()
