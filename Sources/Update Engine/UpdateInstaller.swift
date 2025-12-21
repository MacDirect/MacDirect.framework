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
        
        // 2. Launch via NSWorkspace (LaunchServices)
        // launching directly from the bundle bypasses quarantine issues associated with copying.
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        
        // Note: The helper itself is responsible for copying itself to a temporary location
        // if it needs to survive the main app's termination/replacement.
        // But for the launch itself, we start from the verified bundle location.
        
        let pid = ProcessInfo.processInfo.processIdentifier
        configuration.arguments = [
            "-dmg", dmgURL.path,
            "-dest", destination.path,
            "-pid", String(pid),
            "-mode", "dmg"
        ]
        
        print("[UpdateInstaller] Launching via NSWorkspace (In-Place): \(originalHelperURL.path)")
        print("[UpdateInstaller] Args: \(configuration.arguments)")
        
        try await NSWorkspace.shared.openApplication(at: originalHelperURL, configuration: configuration)
        
        print("[UpdateInstaller] NSWorkspace openApplication returned successfully. Terminating host app...")
        
        // Give the helper a moment to actually start before we kill ourselves
        try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
        NSApp.terminate(nil)
    }
}
