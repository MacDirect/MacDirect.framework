import Foundation
import AppKit

@MainActor
class UpdateInstaller {
    enum InstallError: Error {
        case mountingFailed
        case appNotFoundInDMG
        case signatureVerificationFailed(Error)
        case helperNotFound
        case helperLaunchFailed(String)
        case helperCopyFailed(String)
    }
    
    static func install(dmgURL: URL) async throws {
        print("[UpdateInstaller] Installing from: \(dmgURL.path)")
        
        let destinationURL = Bundle.main.bundleURL
        
        // Launch Helper
        try await launchHelper(dmgURL: dmgURL, destination: destinationURL)
    }
    
    private static func launchHelper(dmgURL: URL, destination: URL) async throws {
        // 1. Locate Helper
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MacDirect.self)
        #endif
        
        guard let originalHelperURL = bundle.url(forResource: "MacDirectUpdater", withExtension: "app") else {
            throw InstallError.helperNotFound
        }
        
        // 2. Write Configuration File
        // The `open --args` mechanism is unreliable for passing arguments to GUI apps
        // launched via LaunchServices in sandboxed contexts. Instead, we write a config
        // file to a known location that the helper can read on startup.
        
        let pid = ProcessInfo.processInfo.processIdentifier
        let config: [String: Any] = [
            "dmg": dmgURL.path,
            "dest": destination.path,
            "pid": pid,
            "mode": "dmg"
        ]
        
        // Write to the sandboxed app's container temp directory
        // The helper will discover the container path from the host app's bundle identifier
        let hostBundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("MacDirectUpdaterConfig.plist")
        
        // Include the host bundle ID so the helper can find the container if needed
        var configWithMeta = config
        configWithMeta["hostBundleId"] = hostBundleId
        let configData = try PropertyListSerialization.data(fromPropertyList: configWithMeta, format: .xml, options: 0)
        try configData.write(to: configURL)
        
        print("[UpdateInstaller] Config written to: \(configURL.path)")
        
        // 3. Launch via /usr/bin/open
        let openTask = Process()
        openTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openTask.arguments = [
            "-n", // Open a new instance even if one is running
            "-a", originalHelperURL.path // Path to the application
        ]
        
        // Also set environment variable pointing to config (backup mechanism)
        var env = ProcessInfo.processInfo.environment
        env["MACDIRECT_CONFIG_PATH"] = configURL.path
        openTask.environment = env
        
        print("[UpdateInstaller] Launching via /usr/bin/open: \(originalHelperURL.path)")
        print("[UpdateInstaller] Cmd: open \(openTask.arguments?.joined(separator: " ") ?? "")")
        
        try openTask.run()
        openTask.waitUntilExit()
        
        print("[UpdateInstaller] 'open' command completed. Terminating host app...")
        
        // Give the helper a moment to actually start before we kill ourselves
        try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
        NSApp.terminate(nil)
    }
}
