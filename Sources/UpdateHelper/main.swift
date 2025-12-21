import AppKit
import MacDirectSecurity

// 1. Logging Helper
// Writes to a log file on the Desktop for debugging visibility.
func log(_ message: String) {
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/MacDirectUpdater.log")
    let entry = "[\(Date().ISO8601Format())] \(message)\n"
    
    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    // Also print to console for Xcode debugging attached to process
    print(entry)
}

@MainActor
class UpdaterDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let rawArgs = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        
        log("Updater started from: \(Bundle.main.bundlePath)")
        log("Raw Arguments: \(rawArgs)")
        
        // 2. Parse Arguments - Multiple fallback mechanisms
        var destPath: String?
        var pid: Int32 = 0
        var dmgPath: String?
        
        // Priority 1: Config File (Most Robust - works reliably from sandboxed apps)
        // The helper is embedded in the host app, so we can discover the host's container
        // by parsing our own bundle path to find the host app's bundle identifier
        
        var configPaths: [URL] = []
        
        // Try to discover host app's container from our bundle path
        // Path looks like: .../Dummy1.app/Contents/Resources/MacDirect_MacDirect.bundle/.../MacDirectUpdater.app
        let bundlePath = Bundle.main.bundlePath
        log("Helper bundle path: \(bundlePath)")
        
        if let hostAppPath = extractHostAppPath(from: bundlePath) {
            log("Discovered host app: \(hostAppPath)")
            
            // Read host app's Info.plist to get bundle identifier
            let hostInfoPlistPath = hostAppPath + "/Contents/Info.plist"
            if let hostInfoDict = NSDictionary(contentsOfFile: hostInfoPlistPath),
               let hostBundleId = hostInfoDict["CFBundleIdentifier"] as? String {
                log("Host bundle identifier: \(hostBundleId)")
                
                // Build path to host's container tmp
                let containerConfigPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Containers")
                    .appendingPathComponent(hostBundleId)
                    .appendingPathComponent("Data/tmp/MacDirectUpdaterConfig.plist")
                configPaths.append(containerConfigPath)
                log("Looking for config at: \(containerConfigPath.path)")
            }
        }
        
        // Also check standard temp directories as fallback
        configPaths.append(contentsOf: [
            FileManager.default.temporaryDirectory.appendingPathComponent("MacDirectUpdaterConfig.plist"),
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacDirectUpdaterConfig.plist"),
            URL(fileURLWithPath: "/private/tmp/MacDirectUpdaterConfig.plist")
        ])
        
        // Also check path from environment variable if set
        if let envConfigPath = env["MACDIRECT_CONFIG_PATH"] {
            let envConfigURL = URL(fileURLWithPath: envConfigPath)
            if loadConfig(from: envConfigURL, destPath: &destPath, pid: &pid, dmgPath: &dmgPath) {
                log("Configuration loaded from env path: \(envConfigPath)")
            }
        }
        
        if destPath == nil {
            for configURL in configPaths {
                log("Checking config path: \(configURL.path)")
                if loadConfig(from: configURL, destPath: &destPath, pid: &pid, dmgPath: &dmgPath) {
                    log("Configuration loaded from config file: \(configURL.path)")
                    break
                }
            }
        }
        
        // Priority 2: Environment Variables (backup)
        if destPath == nil {
            destPath = env["MACDIRECT_DEST_PATH"]
            pid = Int32(env["MACDIRECT_PID"] ?? "0") ?? 0
            dmgPath = env["MACDIRECT_DMG_PATH"]
            if destPath != nil {
                log("Configuration loaded from Environment Variables.")
            }
        }
        
        // Priority 3: UserDefaults (Standard 'open --args' mechanism)
        if destPath == nil {
            let defaults = UserDefaults.standard
            destPath = defaults.string(forKey: "dest")
            if let p = defaults.string(forKey: "pid") { pid = Int32(p) ?? 0 }
            else { pid = Int32(defaults.integer(forKey: "pid")) }
            dmgPath = defaults.string(forKey: "dmg")
            if destPath != nil {
                log("Configuration loaded from UserDefaults.")
            }
        }

        // Priority 4: Manual Parse (Fallback)
        if destPath == nil {
            log("Attempting manual argument parsing...")
            var i = 0
            while i < rawArgs.count {
                let arg = rawArgs[i]
                if (arg == "-dest" || arg == "--dest") && i+1 < rawArgs.count {
                    destPath = rawArgs[i+1]
                } else if (arg == "-pid" || arg == "--pid") && i+1 < rawArgs.count {
                    pid = Int32(rawArgs[i+1]) ?? 0
                } else if (arg == "-dmg" || arg == "--dmg") && i+1 < rawArgs.count {
                    dmgPath = rawArgs[i+1]
                }
                i += 1
            }
            if destPath != nil {
                log("Configuration loaded from command-line arguments.")
            }
        }
        
        log("Configuration: dest=\(destPath ?? "nil"), pid=\(pid), dmg=\(dmgPath ?? "nil")")
        
        guard let destination = destPath, pid > 0, let dmg = dmgPath else {
            log("CRITICAL: Missing required arguments. Terminating.")
            NSApp.terminate(nil)
            return
        }
        
        // 3. Execute Update Task
        Task {
            await performUpdateSequence(dmgPath: dmg, destination: destination, pid: pid)
        }
    }
    
    func performUpdateSequence(dmgPath: String, destination: String, pid: Int32) async {
        // Step A: Wait for Parent App to Quit
        log("Step 1: Waiting for Parent PID \(pid) to exit...")
        await waitForParent(pid: pid)
        
        do {
            let dmgURL = URL(fileURLWithPath: dmgPath)
            
            // Step B: Mount DMG
            log("Step 2: Mounting DMG...")
            let mountPoint = try await mountDMG(at: dmgURL)
            log("Mounted at: \(mountPoint.path)")
            
            defer {
                log("Cleanup: Detaching DMG...")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                task.arguments = ["detach", mountPoint.path, "-force"]
                try? task.run()
                task.waitUntilExit()
            }
            
            // Step C: Find App in DMG
            log("Step 3: Locating .app in DMG...")
            guard let sourceAppURL = findApp(in: mountPoint) else {
                log("Error: No .app found in DMG")
                NSApp.terminate(nil)
                return
            }
            log("Found: \(sourceAppURL.path)")
            
            // Step D: Extract to Temp (Atomic Prep)
            // We copy from DMG to a temp folder first to ensure we aren't reading from the DMG while writing
            log("Step 4: Extracting to Staging...")
            let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagedAppURL = stagingDir.appendingPathComponent(sourceAppURL.lastPathComponent)
            
            try FileManager.default.copyItem(at: sourceAppURL, to: stagedAppURL)
            
            // Step E: Perform Swap
            log("Step 5: Performing Swap...")
            let destURL = URL(fileURLWithPath: destination)
            
            // Try standard move
            do {
                try swapFiles(src: stagedAppURL, dest: destURL)
                log("Swap Successful.")
                finishAndRelaunch(target: destURL)
            } catch {
                log("Standard swap failed: \(error). Attempting Privileged Swap...")
                do {
                    try privilegedSwap(src: stagedAppURL, dest: destURL)
                    log("Privileged Swap Successful.")
                    finishAndRelaunch(target: destURL)
                } catch {
                    log("Privileged Swap Failed: \(error)")
                    NSApp.terminate(nil)
                }
            }
            
        } catch {
            log("Update Failed: \(error)")
            // Fallback: Just re-open the old app
            NSWorkspace.shared.open(URL(fileURLWithPath: destination))
            NSApp.terminate(nil)
        }
    }
    
    func waitForParent(pid: Int32) async {
        let timeout: TimeInterval = 15.0
        let start = Date()
        
        // Loop while process exists
        while kill(pid, 0) == 0 {
            if Date().timeIntervalSince(start) > timeout {
                log("Warning: Parent PID timed out. Proceeding anyway.")
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        }
        log("Parent process exited.")
    }
    
    func swapFiles(src: URL, dest: URL) throws {
        let fileManager = FileManager.default
        let backupURL = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".bak")
        
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.moveItem(at: dest, to: backupURL)
        }
        
        try fileManager.moveItem(at: src, to: dest)
        try? fileManager.removeItem(at: backupURL)
    }
    
    func privilegedSwap(src: URL, dest: URL) throws {
        let script = """
        rm -rf "\(dest.path).bak"
        mv "\(dest.path)" "\(dest.path).bak"
        mv "\(src.path)" "\(dest.path)"
        rm -rf "\(dest.path).bak"
        """
        
        // Note: Administrative privileges might prompt the user
        let appleScript = "do shell script \"\(script)\" with administrator privileges"
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                throw NSError(domain: "Updater", code: 1, userInfo: error as? [String : Any])
            }
        }
    }
    
    func finishAndRelaunch(target: URL) {
        log("Relaunching: \(target.path)")
        
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, error in
            if let error = error { log("Relaunch Error: \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    
    // Helpers
    func mountDMG(at url: URL) async throws -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", "-nobrowse", "-plist", url.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        }
        throw NSError(domain: "Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mount failed"])
    }
    
    func findApp(in folder: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return contents?.first { $0.pathExtension == "app" }
    }
    
    func loadConfig(from url: URL, destPath: inout String?, pid: inout Int32, dmgPath: inout String?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        
        destPath = plist["dest"] as? String
        dmgPath = plist["dmg"] as? String
        if let pidValue = plist["pid"] as? Int {
            pid = Int32(pidValue)
        } else if let pidString = plist["pid"] as? String {
            pid = Int32(pidString) ?? 0
        }
        
        // Clean up the config file after reading to avoid stale data
        try? FileManager.default.removeItem(at: url)
        
        return destPath != nil && dmgPath != nil && pid > 0
    }
    
    /// Extracts the host app path from the helper's bundle path
    /// The helper is embedded like: .../HostApp.app/Contents/Resources/.../MacDirectUpdater.app
    /// We want to find the first .app in the path (which is the host app)
    func extractHostAppPath(from helperPath: String) -> String? {
        // Split the path and find the first component ending with .app
        let components = helperPath.components(separatedBy: "/")
        var pathSoFar = ""
        
        for component in components {
            if component.isEmpty { continue }
            pathSoFar += "/" + component
            
            // Check if this is an .app but NOT our own updater app
            if component.hasSuffix(".app") && !component.contains("MacDirectUpdater") {
                return pathSoFar
            }
        }
        
        return nil
    }
}

let app = NSApplication.shared
let delegate = UpdaterDelegate()
app.delegate = delegate
app.run()
