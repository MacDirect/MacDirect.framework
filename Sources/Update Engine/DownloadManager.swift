//
//  DownloadManager.swift
//  MacDirect.framework
//
//  Created by Bregas Satria Wicaksono on 14/12/25.
//

import Foundation
import Combine
import AppKit

@MainActor
final class DownloadManager: NSObject, URLSessionDownloadDelegate, ObservableObject {
    @Published var progress: Double = 0.0
    private var continuation: CheckedContinuation<URL, Error>?
    
    // Shared instance for simplicity in this MVP context, though normally we'd inject.
    static let shared = DownloadManager()
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func downloadUpdate(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a permanent temporary location so it doesn't get deleted immediately
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(downloadTask.response?.suggestedFilename ?? "update.dmg")
        
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            Task { @MainActor in
                self.continuation?.resume(returning: destinationURL)
                self.continuation = nil
            }
        } catch {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let percentage = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.progress = percentage
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
            }
        }
    }
}

// MARK: - Update Installer

class UpdateInstaller {
    enum InstallError: Error {
        case mountingFailed
        case appNotFoundInDMG
        case swapFailed(String)
    }
    
    /// Installs the update from a DMG file.
    /// This process involves mounting, copying, swapping, and relaunching.
    static func install(dmgURL: URL) async throws {
        print("[UpdateInstaller] Installing from: \(dmgURL.path)")
        
        // 1. Mount DMG
        let mountPoint = try await mountDMG(at: dmgURL)
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
        
        // 3. Prepare Destination
        let currentAppURL = Bundle.main.bundleURL
        let backupURL = currentAppURL.deletingLastPathComponent().appendingPathComponent("\(currentAppURL.lastPathComponent).bak")
        
        do {
            // Atomic Swap Logic (Simulated for running app constraints or assisted by helper)
            
            // Move current -> backup
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: currentAppURL, to: backupURL)
            
            // Copy new -> current
            try FileManager.default.copyItem(at: appURL, to: currentAppURL)
            
            // If successful, relaunch
            relaunch(at: currentAppURL)
            
        } catch {
            // Rollback if possible
            if FileManager.default.fileExists(atPath: backupURL.path) && !FileManager.default.fileExists(atPath: currentAppURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            }
            throw InstallError.swapFailed(error.localizedDescription)
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
    
    private static func relaunch(at appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Delta Patch Builder

class DeltaPatchBuilder {
    enum PatchError: Error {
        case fileNotFound
        case patchFailed
    }
    
    /// Creates a patch file that transforms `oldFile` into `newFile`.
    static func createPatch(from oldFile: URL, to newFile: URL, output: URL) async throws {
        // MVP Placeholder
        guard FileManager.default.fileExists(atPath: oldFile.path),
              FileManager.default.fileExists(atPath: newFile.path) else {
            throw PatchError.fileNotFound
        }
        
        // Simulate processing work
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Write a dummy "patch" file
        let dummyData = "MACDIRECT_PATCH_V1".data(using: .utf8)!
        try dummyData.write(to: output)
    }
    
    /// Applies `patch` to `oldFile` to reconstruct the `newFile`.
    static func applyPatch(patch: URL, to oldFile: URL, output: URL) async throws {
        // MVP Placeholder
        guard FileManager.default.fileExists(atPath: patch.path),
              FileManager.default.fileExists(atPath: oldFile.path) else {
            throw PatchError.fileNotFound
        }
        
        // Verify it's our dummy patch
        let patchData = try Data(contentsOf: patch)
        guard let header = String(data: patchData, encoding: .utf8), header.contains("MACDIRECT_PATCH_V1") else {
            throw PatchError.patchFailed
        }
        
        try FileManager.default.copyItem(at: oldFile, to: output)
    }
}
