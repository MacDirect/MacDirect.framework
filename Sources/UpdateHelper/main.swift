import Foundation

// MacDirectUpdateHelper
// Arguments: version, sourcePath, destinationPath, pidToWait

guard CommandLine.arguments.count >= 4 else {
    print("Usage: MacDirectUpdateHelper <version> <sourcePath> <destinationPath> <pidToWait>")
    exit(1)
}

let version = CommandLine.arguments[1]
let sourcePath = CommandLine.arguments[2]
let destinationPath = CommandLine.arguments[3]
let pidString = CommandLine.arguments[4]

guard let pid = Int32(pidString) else {
    print("Invalid PID")
    exit(1)
}

    // 1. Wait for parent app to exit
    print("Waiting for PID \(pid) to exit...")
    let timeout: TimeInterval = 30.0
    let start = Date()
    
    while kill(pid, 0) == 0 {
        if Date().timeIntervalSince(start) > timeout {
            print("Parent app failed to exit within \(timeout) seconds. Aborting.")
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("Parent app exited.")
    
    // 2. Perform Swap
    let fileManager = FileManager.default
    let destinationURL = URL(fileURLWithPath: destinationPath)
    let sourceURL = URL(fileURLWithPath: sourcePath)
    
    let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent("\(destinationURL.lastPathComponent).bak")
    
    do {
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        
        // Move current app to .bak
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.moveItem(at: destinationURL, to: backupURL)
        }
        
        // Move new app to destination
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        
        print("Swap complete.")
        
        // Cleanup backup
        try? fileManager.removeItem(at: backupURL)
        
        // 3. Relaunch
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [destinationPath]
        try process.run()
        
        exit(0)
    } catch {
        print("Update failed: \(error)")
        // Try to rollback
        if fileManager.fileExists(atPath: backupURL.path) && !fileManager.fileExists(atPath: destinationURL.path) {
             try? fileManager.moveItem(at: backupURL, to: destinationURL)
        }
        exit(1)
    }
