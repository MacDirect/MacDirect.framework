import Foundation
import CryptoKit

/// Responsible for creating a delta patch between two application bundles.
/// The patch consists of:
/// 1. A manifest listing changes (additions, modifications, deletions).
/// 2. Payload containing the new/modified files.
public class DeltaPatchBuilder {
    
    public enum Error: Swift.Error {
        case invalidBundle(String)
        case diffFailed(String)
        case patchCreationFailed(String)
    }
    
    struct PatchManifest: Codable {
        let version: String
        let deletions: [String] // Relative paths to delete
        // Note: Additions/Modifications are implicit by presence in the payload
    }
    
    /// Creates a patch file (Zip) from sourceApp to targetApp.
    /// - Parameters:
    ///   - sourceApp: The underlying (older) app bundle URL.
    ///   - targetApp: The new app bundle URL.
    ///   - outputURL: Where to save the .mdp (MacDirect Patch) file.
    public func createPatch(sourceApp: URL, targetApp: URL, outputURL: URL) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payloadDir = tempDir.appendingPathComponent("Payload")
        
        try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        
        // 1. Scan both bundles
        let sourceFiles = try scanBundle(at: sourceApp)
        let targetFiles = try scanBundle(at: targetApp)
        
        var deletions: [String] = []
        
        // 2. Identify Deletions (In Source but not in Target)
        for (path, _) in sourceFiles {
            if targetFiles[path] == nil {
                deletions.append(path)
            }
        }
        
        // 3. Identify Additions/Modifications (Different or New in Target)
        for (path, targetHash) in targetFiles {
            let sourceHash = sourceFiles[path]
            
            if sourceHash != targetHash {
                // Determine destination path in Payload
                // To preserve directory structure: Payload/Contents/MacOS/MyApp
                let sourceFile = targetApp.appendingPathComponent(path)
                let destFile = payloadDir.appendingPathComponent(path)
                
                try fileManager.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceFile, to: destFile)
            }
        }
        
        // 4. Write Manifest
        let manifest = PatchManifest(version: "1.0", deletions: deletions)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        
        // 5. Zip the result (Payload + Manifest) -> .mdp
        // We use 'ditto' to preserve permissions/attributes inside the payload
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", tempDir.path, outputURL.path]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw Error.patchCreationFailed("Ditto failed to create archive")
        }
        
        // Cleanup
        try? fileManager.removeItem(at: tempDir)
    }
    
    // Returns map of RelativePath -> SHA256 Checksum
    private func scanBundle(at bundleURL: URL) throws -> [String: String] {
        var results: [String: String] = [:]
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw Error.invalidBundle("Could not enumerate bundle")
        }
        
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues.isRegularFile == true {
                // Compute relative path
                let path = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
                // Skip .DS_Store
                if path.hasSuffix(".DS_Store") { continue }
                
                // For Info.plist or binary, we always want accurate hash.
                // For signature (_CodeSignature), we MUST include it if changed (it always will be).
                
                let hash = try computeHash(for: fileURL)
                results[path] = hash
            }
        }
        
        return results
    }
    
    private func computeHash(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var digest = SHA256()
        while let data = try? handle.read(upToCount: 8192) {
            digest.update(data: data)
            if data.isEmpty { break }
        }
        
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
