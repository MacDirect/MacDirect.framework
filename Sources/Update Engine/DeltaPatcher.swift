import Foundation

/// Responsible for applying a delta patch (.mdp) to the current application bundle.
/// Returns the URL to the newly reconstructed and patched Bundle.
public class DeltaPatcher {
    
    public enum Error: Swift.Error {
        case patchNotFound
        case unzippingFailed
        case invalidManifest
        case applicationFailed(String)
    }
    
    struct PatchManifest: Codable {
        let version: String
        let deletions: [String]
    }
    
    /// Applies the patch at patchURL to the bundle at sourceBundleURL.
    /// Returns the URL of the fully patched and reconstructed bundle (in a temp location).
    public func applyPatch(patchURL: URL, sourceBundleURL: URL) async throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("DeltaApply_\(UUID().uuidString)")
        
        // 1. Unzip Path
        let extractedPatchDir = tempDir.appendingPathComponent("Patch")
        try fileManager.createDirectory(at: extractedPatchDir, withIntermediateDirectories: true)
        
        if !unzip(archive: patchURL, destination: extractedPatchDir) {
            throw Error.unzippingFailed
        }
        
        // 2. Read Manifest
        // The zip structure created by DeltaPatchBuilder 'ditto' with --keepParent wraps the contents in the temp folder name if not careful.
        // Let's assume standard structure.
        // Wait, ditto -k --keepParent creates the folder itself? 
        // We used: ditto -c -k --keepParent tempDir.path outputURL.path
        // If tempDir had "manifest.json" and "Payload/", then unzipping should yield those.
        
        // Let's find manifest inside.
        // If the archive was created with the PARENT folder as root, we might have a subdirectory.
        // Let's search one level deep.
        
        var rootDir = extractedPatchDir
        if !fileManager.fileExists(atPath: rootDir.appendingPathComponent("manifest.json").path) {
            let contents = try fileManager.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)
            if let firstDir = contents.first(where: { $0.hasDirectoryPath }) {
                rootDir = firstDir
            }
        }
        
        let manifestURL = rootDir.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw Error.invalidManifest
        }
        
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PatchManifest.self, from: manifestData)
        
        // 3. Prepare Work Copy of App
        // Copy current app to a "Staged" location
        let stagedAppURL = tempDir.appendingPathComponent(sourceBundleURL.lastPathComponent)
        try fileManager.copyItem(at: sourceBundleURL, to: stagedAppURL)
        
        // 4. Apply Deletions
        for deletionPath in manifest.deletions {
            let fileToDelete = stagedAppURL.appendingPathComponent(deletionPath)
            if fileManager.fileExists(atPath: fileToDelete.path) {
                try? fileManager.removeItem(at: fileToDelete)
            }
        }
        
        // 5. Apply Payload (Additions/Modifications)
        // Payload folder is at rootDir/Payload
        let payloadDir = rootDir.appendingPathComponent("Payload")
        
        if fileManager.fileExists(atPath: payloadDir.path) {
        if fileManager.fileExists(atPath: payloadDir.path) {
            // Use subpathsOfDirectory to avoid async iterator issues with NSDirectoryEnumerator
            if let subpaths = try? fileManager.subpathsOfDirectory(atPath: payloadDir.path) {
                for relativePath in subpaths {
                    let fileURL = payloadDir.appendingPathComponent(relativePath)
                    
                    // Skip directories, we create them implicitly or explicitly
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        try? fileManager.createDirectory(at: stagedAppURL.appendingPathComponent(relativePath), withIntermediateDirectories: true)
                        continue
                    }
                    
                    // If file, copy/overwrite
                    let destURL = stagedAppURL.appendingPathComponent(relativePath)
                    try? fileManager.removeItem(at: destURL)
                    // Ensure parent directory exists
                    try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: fileURL, to: destURL)
                }
            }
        }
        }
        
        // Cleanup patch files
        try? fileManager.removeItem(at: extractedPatchDir)
        
        return stagedAppURL
    }
    
    private func unzip(archive: URL, destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
