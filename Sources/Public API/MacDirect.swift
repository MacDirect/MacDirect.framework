import Foundation
import SwiftUI

@objc(MacDirect)
@MainActor
public final class MacDirect: NSObject { 
    public static let shared = MacDirect()
    
    private var feedURL: URL?
    private let updateChecker = UpdateChecker()
    
    private override init() {
        super.init()
    }
    
    /// Configures the MacDirect updater with your feed URL.
    /// - Parameter feedURL: The URL to your updates.json file.
    @objc public static func configure(feedURL: String) {
        guard let url = URL(string: feedURL) else {
            print("[MacDirect] Invalid feed URL: \(feedURL)")
            return
        }
        LocalState.shared.feedURL = url
        
        // Sandbox Check (Informational)
        if isSandboxed() {
             print("[MacDirect] App Sandbox detected. Using Helper Tool for safe updates.")
        }
        
        print("[MacDirect] Configured with feed: \(url)")
    }
    
    private static func isSandboxed() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
    
    /// Manually checks for updates.
    ///Returns the update info if available, or nil if up to date/error.
    public static func checkForUpdates() async throws -> UpdateInfo? {
        guard let url = LocalState.shared.feedURL else {
            throw MacDirectError.notConfigured
        }
        return try await shared.updateChecker.check(feedURL: url)
    }
    
    /// Presents the standard update UI if an update is available.
    @MainActor
    @objc public static func presentUpdateProfileIfAvailable() {
        print("[MacDirect] Automatically checking for updates...")
        Task {
            do {
                if let update = try await checkForUpdates() {
                    print("[MacDirect] Update available: \(update.version)")
                    presentUpdateWindow(for: update)
                } else {
                    print("[MacDirect] No updates available.")
                }
            } catch {
                print("[MacDirect] Automatic update check failed: \(error)")
            }
        }
    }
    
    /// Checks for updates manually and showing UI feedback even if no update is found.
    @MainActor
    @objc public static func checkForUpdatesManually() {
        print("[MacDirect] Manually checking for updates...")
        Task {
            do {
                if let update = try await checkForUpdates() {
                    print("[MacDirect] Update available: \(update.version)")
                    presentUpdateWindow(for: update)
                } else {
                    print("[MacDirect] No updates available.")
                    let alert = NSAlert()
                    alert.messageText = "You're up to date!"
                    alert.informativeText = "\(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "This app") \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") is the latest version."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                print("[MacDirect] Manual update check failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Check for Updates Failed"
                alert.informativeText = "There was an error checking for updates: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    
    @MainActor
    private static func presentUpdateWindow(for update: UpdateInfo) {
        let alert = UpdateAlert(update: update)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.center()
        window.contentView = NSHostingView(rootView: alert)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
class LocalState {
    static let shared = LocalState()
    var feedURL: URL?
}

public enum MacDirectError: Error {
    case notConfigured
}
