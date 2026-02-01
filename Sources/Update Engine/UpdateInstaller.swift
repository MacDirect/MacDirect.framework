import Foundation
import AppKit

@MainActor
class UpdateInstaller {
    enum InstallError: Error {
        case mountingFailed
        case appNotFoundInDMG
        case signatureVerificationFailed(AppError)
        case helperNotFound
        case helperLaunchFailed(String)
        case helperCopyFailed(String)
        case zipExtractionFailed
        case appNotFoundInZip
    }
    
    static func install(artifactURL: URL) async throws {
        print("[UpdateInstaller] Installing from: \(artifactURL.path)")
        
        let destinationURL = Bundle.main.bundleURL
        
        // Determine mode
        let mode: String
        switch artifactURL.pathExtension.lowercased() {
        case "dmg": mode = "dmg"
        case "zip": mode = "zip"
        case "pkg": mode = "pkg"
        case "app": mode = "app"
        default: mode = "dmg" // Fallback
        }
        
        // SECURITY: Verify Team ID before proceeding with installation
        // This is the "MacDirect" equivalent of Sparkle's SUPublicEDKey verification
        try await verifyTeamIDMatch(artifactURL: artifactURL, mode: mode)
        
        // Launch Helper
        try await launchHelper(artifactURL: artifactURL, destination: destinationURL, mode: mode)
    }
    
    /// Verifies that the update is signed by the same developer as the current app.
    private static func verifyTeamIDMatch(artifactURL: URL, mode: String) async throws {
        print("[UpdateInstaller] Verifying Team ID match...")
        
        // Get the Team ID of the CURRENT running app
        let currentTeamID = try await CodeSignVerifier.getTeamID(at: Bundle.main.bundleURL)
        print("[UpdateInstaller] Current app Team ID: \(currentTeamID)")
        
        let newAppTeamID: String
        
        switch mode {
        case "dmg":
            // Mount DMG, find app, get Team ID, unmount
            let (mountPoint, tempAppURL) = try await mountDMGAndFindApp(dmgURL: artifactURL)
            defer {
                // Unmount the DMG
                let unmountProcess = Process()
                unmountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                unmountProcess.arguments = ["detach", mountPoint.path, "-quiet"]
                try? unmountProcess.run()
                unmountProcess.waitUntilExit()
            }
            newAppTeamID = try await CodeSignVerifier.getTeamID(at: tempAppURL)
            
        case "zip":
            // Extract ZIP, find app, get Team ID, cleanup
            let (extractDir, tempAppURL) = try await extractZipAndFindApp(zipURL: artifactURL)
            defer {
                // Cleanup extracted directory
                try? FileManager.default.removeItem(at: extractDir)
            }
            newAppTeamID = try await CodeSignVerifier.getTeamID(at: tempAppURL)
            
        case "app":
            // Direct app bundle
            newAppTeamID = try await CodeSignVerifier.getTeamID(at: artifactURL)
            
        case "pkg":
            // PKG verification is handled differently - skip for now
            // The PKG installer itself should be signed
            print("[UpdateInstaller] PKG mode - Team ID verification delegated to system installer")
            return
            
        default:
            print("[UpdateInstaller] Unknown mode - skipping Team ID verification")
            return
        }
        
        print("[UpdateInstaller] Update app Team ID: \(newAppTeamID)")
        
        guard currentTeamID == newAppTeamID else {
            throw InstallError.signatureVerificationFailed(
                AppError(
                    title: "Security Alert",
                    description: "The update is not signed by the same developer. Update aborted.\n\nExpected Team ID: \(currentTeamID)\nActual Team ID: \(newAppTeamID)"
                )
            )
        }
        
        print("[UpdateInstaller] ✅ Team ID verification passed")
    }
    
    /// Mounts a DMG and finds the .app inside it.
    private static func mountDMGAndFindApp(dmgURL: URL) async throws -> (mountPoint: URL, appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw InstallError.mountingFailed
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw InstallError.mountingFailed
        }
        
        // Find the mount point
        var mountPoint: URL?
        for entity in entities {
            if let mount = entity["mount-point"] as? String {
                mountPoint = URL(fileURLWithPath: mount)
                break
            }
        }
        
        guard let mount = mountPoint else {
            throw InstallError.mountingFailed
        }
        
        // Find .app in mount point
        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.appNotFoundInDMG
        }
        
        return (mount, appURL)
    }
    
    /// Extracts a ZIP and finds the .app inside it.
    private static func extractZipAndFindApp(zipURL: URL) async throws -> (extractDir: URL, appURL: URL) {
        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", extractDir.path]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw InstallError.zipExtractionFailed
        }
        
        // Find .app in extracted directory
        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.appNotFoundInZip
        }
        
        return (extractDir, appURL)
    }
    
    private static func launchHelper(artifactURL: URL, destination: URL, mode: String) async throws {
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
            "artifact": artifactURL.path,
            "dest": destination.path,
            "pid": pid,
            "mode": mode
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
