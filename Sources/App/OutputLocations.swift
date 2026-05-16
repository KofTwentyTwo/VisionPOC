import Foundation
import AppKit

/// User-configurable destinations for snapshot PNGs and screen recordings.
/// Persisted via UserDefaults so choices survive across launches. Both
/// default to ~/Desktop. Access from MainActor only; UserDefaults itself is
/// thread-safe but the surrounding presentation logic (NSOpenPanel) is not.
@MainActor
enum OutputLocations {
    private static let snapshotKey  = "VPOC.SnapshotDirectoryBookmark"
    private static let recordingKey = "VPOC.RecordingDirectoryBookmark"

    /// Resolves a stored security-scoped bookmark back into a directory URL
    /// (with `startAccessingSecurityScopedResource` already called). Falls
    /// back to ~/Desktop when no bookmark is stored or it can't be resolved.
    /// The caller MUST balance with `endAccessing` when done writing.
    static func snapshotDirectory() -> URL {
        resolve(key: snapshotKey) ?? defaultDesktop()
    }

    static func recordingDirectory() -> URL {
        resolve(key: recordingKey) ?? defaultDesktop()
    }

    /// Stores `url` as a security-scoped bookmark under the chosen key so
    /// the choice survives sandboxing if we ever sign + sandbox the app.
    static func setSnapshotDirectory(_ url: URL) {
        store(url: url, key: snapshotKey)
    }

    static func setRecordingDirectory(_ url: URL) {
        store(url: url, key: recordingKey)
    }

    static func snapshotDisplayPath() -> String {
        displayPath(for: snapshotDirectory())
    }

    static func recordingDisplayPath() -> String {
        displayPath(for: recordingDirectory())
    }

    /// Opens an NSOpenPanel and runs `completion` on MainActor with the
    /// chosen URL, or nil if the user cancelled. Use from the Settings
    /// panel's folder-picker buttons.
    static func chooseDirectory(title: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDesktop()
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            completion(url)
        } else {
            completion(nil)
        }
    }

    // MARK: - Private

    private static func defaultDesktop() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func store(url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Sandbox-less builds may reject .withSecurityScope. Fall back to
            // a plain bookmark; both will resolve fine without entitlements.
            do {
                let data = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(data, forKey: key)
            } catch {
                NSLog("OutputLocations: failed to store bookmark for \(key): \(error)")
            }
        }
    }

    private static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        // Try security-scoped resolution first, then a plain resolve. Either
        // path returns a URL the caller can write into for the lifetime of
        // this process.
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            return url
        }
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        return nil
    }
}
