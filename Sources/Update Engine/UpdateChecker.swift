//
//  UpdateChecker.swift
//  MacDirect.framework
//
//  Created by Bregas Satria Wicaksono on 14/12/25.
//

import Foundation

public struct UpdateInfo: Codable {
    public let version: String
    public let releaseNotes: String
    public let downloadURL: URL
}

@MainActor
class UpdateChecker {
    func check(feedURL: URL) async throws -> UpdateInfo? {
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        // This mirrors the UpdateFeed struct but for client consumption
        // We define a local private struct to parse the full feed first
        let feed = try JSONDecoder().decode(ClientUpdateFeed.self, from: data)
        
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        
        if compareVersions(feed.latestVersion.version, isGreaterThan: currentVersion) {
            return UpdateInfo(
                version: feed.latestVersion.version,
                releaseNotes: feed.latestVersion.releaseNotes,
                downloadURL: feed.latestVersion.downloads.full.url
            )
        }
        
        return nil
    }
    
    private func compareVersions(_ v1: String, isGreaterThan v2: String) -> Bool {
        return v1.compare(v2, options: .numeric) == .orderedDescending
    }
}

// Minimal matching structs for parsing
private struct ClientUpdateFeed: Codable {
    struct VersionInfo: Codable {
        let version: String
        let releaseNotes: String
        let downloads: Downloads
        
        struct Downloads: Codable {
            let full: DownloadAsset
        }
        
        struct DownloadAsset: Codable {
            let url: URL
        }
        
        enum CodingKeys: String, CodingKey {
            case version
            case releaseNotes = "release_notes"
            case downloads
        }
    }
    
    let latestVersion: VersionInfo
    
    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
    }
}
