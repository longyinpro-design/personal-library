import Foundation

/// Where the library lives when nobody passes a path. Shared with App Intents so
/// a note saved from Shortcuts lands in the same library the app opens.
public enum LibraryLocation {
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["PERSONAL_LIBRARY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalLibrary", isDirectory: true)
    }
}
