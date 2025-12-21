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
        log("Updater started from: \(Bundle.main.bundlePath)")
        log("Raw Arguments: \(rawArgs)")
        
        // 2. Parse Arguments
        // 'open --args' usually populates UserDefaults.standard
        let defaults = UserDefaults.standard
        
        var destPath = defaults.string(forKey: "dest")
        var pid = Int32(defaults.integer(forKey: "pid"))
        var dmgPath = defaults.string(forKey: "dmg")
        
        // Fallback: Manual Parse (If UserDefaults fails for any reason)
        if destPath == nil {
            log("UserDefaults empty. Attempting manual argument parsing.")
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
}

let app = NSApplication.shared
let delegate = UpdaterDelegate()
app.delegate = delegate
app.run()
