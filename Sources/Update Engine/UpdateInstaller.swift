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
    }
    
    /// Installs the update from a DMG file.
    /// This process involves mounting, verifying, and launching the helper tool to swap the app.
    static func install(dmgURL: URL) async throws {
        let gotAccess = dmgURL.startAccessingSecurityScopedResource()
        defer {
            if gotAccess {
                dmgURL.stopAccessingSecurityScopedResource()
            }
        }
        
        print("[UpdateInstaller] Installing from: \(dmgURL.path)")
        
        // 1. Mount DMG
        let mountPoint = try await mountDMG(at: dmgURL)
        // Note: We DO NOT defer unmount here because the helper tool needs to read from it?
        // Actually, helper copies NEW -> Dest. If we unmount, helper can't copy.
        // So we should COPY the new app to a temp location FIRST, then unmount, then launch helper.
        
        defer {
            // Cleanup: Try to unmount
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            task.arguments = ["detach", mountPoint.path]
            try? task.run()
        }
        
        // 2. Find .app in DMG
        guard let appURL = findApp(in: mountPoint) else {
            throw InstallError.appNotFoundInDMG
        }
        
        // 3. Security Check: Verify Team ID
        do {
            // Use Bundle.main for the running app's Team ID
            // In a framework test harness, this might be ad-hoc, but for prod it works.
            let currentTeamID = try await CodeSignVerifier.getTeamID(at: Bundle.main.bundleURL)
            try await CodeSignVerifier.verifyTeamID(appURL: appURL, expectedTeamID: currentTeamID)
            print("[UpdateInstaller] Signature verified. Team ID: \(currentTeamID)")
        } catch {
            print("[UpdateInstaller] Signature verification failed: \(error)")
            throw InstallError.signatureVerificationFailed(error)
        }
        
        // 4. Prepare for Helper
        // Copy new app to a safe temp location so we can unmount the DMG
        let tempDir = FileManager.default.temporaryDirectory
        // Use a unique folder
        let updateDir = tempDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
        
        let stagedAppURL = updateDir.appendingPathComponent(appURL.lastPathComponent)
        try FileManager.default.copyItem(at: appURL, to: stagedAppURL)
        
        // 5. Launch Helper
        try launchHelper(source: stagedAppURL, destination: Bundle.main.bundleURL)
    }
    
    private static func launchHelper(source: URL, destination: URL) throws {
        // Locate Helper Binary
        var helperBinaryURL: URL?
        
        let bundle = Bundle(for: MacDirect.self)
        if let url = bundle.url(forResource: "MacDirectUpdateHelper", withExtension: nil) {
            helperBinaryURL = url
        } else if let url = Bundle.main.url(forResource: "MacDirectUpdateHelper", withExtension: nil) {
            helperBinaryURL = url
        }
        
        guard let validHelperURL = helperBinaryURL else {
            print("[UpdateInstaller] Helper not found in bundle.")
            throw InstallError.helperNotFound
        }
        
        // Prepare location in Application Support to avoid Tmp/Gatekeeper issues
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Identifier for our support folder. Use bundle ID or generic
        let appSupportDir = appSupport.appendingPathComponent("MacDirect/UpdateEngine", isDirectory: true)
        
        try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        let destBinaryURL = appSupportDir.appendingPathComponent("MacDirectUpdateHelper")
        
        // Always copy fresh to ensure we have latest logic
        if fileManager.fileExists(atPath: destBinaryURL.path) {
            try fileManager.removeItem(at: destBinaryURL)
        }
        try fileManager.copyItem(at: validHelperURL, to: destBinaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinaryURL.path)
        
        // Launch via Process (detached)
        // Arguments: v1, source, destination, pid
        let pid = ProcessInfo.processInfo.processIdentifier
        let arguments = ["v1", source.path, destination.path, String(pid)]
        
        let task = Process()
        task.executableURL = destBinaryURL
        task.arguments = arguments
        
        // To ensure the process survives our exit, we rely on Process running independently?
        // Standard Process() kills child when parent dies unless we protect it?
        // Actually, for CLI tool, we can use `open` or `nohup` logic or launch as a daemon?
        // The previous code used NSWorkspace.openApplication which is safe.
        // But NSWorkspace requires an .app or .service usually.
        // Let's use `open` pointing to the binary.
        
        // Alternatively using `Process` with proper setup:
        // But if we want to be safe, `open` command on the binary runs it in a new terminal/execution context?
        // Actually 'open' on a binary executes it in Terminal. We don't want that.
        // Let's use Process but ensure we don't terminate it.
        // Swift Process doesn't auto-terminate child on deinit, but let's be sure.
        
        print("[UpdateInstaller] Launching Updater: \(destBinaryURL.path) with args: \(arguments)")
        
        do {
            try task.run()
            // We do NOT waitUntilExit. We want it to run.
            
            // Terminate self now.
             print("[UpdateInstaller] Updater launched successfully. Terminating app.")
             DispatchQueue.main.async {
                 NSApp.terminate(nil)
             }
        } catch {
             print("[UpdateInstaller] Failed to launch updater: \(error)")
             throw InstallError.helperLaunchFailed(error.localizedDescription)
        }
    }
    
    private static func mountDMG(at url: URL) async throws -> URL {
        // hdiutil attach -nobrowse -plist <url>
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", "-nobrowse", "-plist", url.path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        
        // Parse Plist to find mount-point
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        }
        
        throw InstallError.mountingFailed
    }
    
    private static func findApp(in folder: URL) -> URL? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        
        return contents.first { $0.pathExtension == "app" }
    }
}
