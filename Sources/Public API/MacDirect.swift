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
        print("[MacDirect] Configured with feed: \(url)")
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
        Task {
            do {
                if let update = try await checkForUpdates() {
                    // In a real framework, we'd use NSWindow/NSAlert or a ViewModifier
                    // For MVP, we'll print to console or try to find key window
                    print("[MacDirect] Update available: \(update.version)")
                    presentUpdateWindow(for: update)
                } else {
                    print("[MacDirect] No updates available.")
                }
            } catch {
                print("[MacDirect] Update check failed: \(error)")
            }
        }
    }
    
    @MainActor
    private static func presentUpdateWindow(for update: UpdateInfo) {
        let alert = UpdateAlert(update: update)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
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
