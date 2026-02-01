//
//  UpdateAlert.swift
//  MacDirect.framework
//
//  Created by Bregas Satria Wicaksono on 14/12/25.
//

import SwiftUI

struct UpdateAlert: View {
    let update: UpdateInfo
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var isDownloading: Bool = false
    @State private var isReadyToInstall: Bool = false
    @State private var isInstalling: Bool = false
    @State private var downloadedDMGURL: URL?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading) {
                    Text("A new version of \(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App") is available!")
                        .font(.headline)
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0") -> \(update.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            if let error = errorMessage {
                 Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }
            
            if isDownloading || isInstalling {
                VStack(spacing: 8) {
                    ProgressView(value: downloadManager.progress)
                    Text(isInstalling ? "Installing..." : "Downloading... \(Int(downloadManager.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 150)
            } else if isReadyToInstall {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Update Downloaded")
                        .font(.title3)
                    Text("The application will restart to complete the update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: 150)
            } else {
                ScrollView {
                    Text(update.releaseNotes)
                        .font(.body)
                }
                .frame(height: 150)
            }
            
            HStack {
                Button("Skip This Version") {
                    NSApp.keyWindow?.close()
                }
                .disabled(isDownloading || isInstalling)
                
                Spacer()
                
                if isReadyToInstall {
                    Button("Install on Quit") {
                        // TODO: Persist intent to install on quit
                        NSApp.keyWindow?.close()
                    }
                    
                    Button("Restart & Install") {
                        performInstall()
                    }
                    .buttonStyle(.borderedProminent)
                } else if !isDownloading && !isInstalling {
                    Button("Remind Me Later") {
                        NSApp.keyWindow?.close()
                    }
                    
                    Button("Install Update") {
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        // Cancel logic
                        NSApp.keyWindow?.close()
                    }
                    .disabled(isInstalling)
                }
            }
        }
        .padding()
        .frame(width: 500, height: 320)
    }
    
    private func startDownload() {
        let url = update.downloadURL
        isDownloading = true
        errorMessage = nil
        
        Task {
            do {
                let dmgLocation = try await downloadManager.downloadUpdate(from: url)
                
                await MainActor.run {
                    self.downloadedDMGURL = dmgLocation
                    self.isDownloading = false
                    self.isReadyToInstall = true
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func performInstall() {
        guard let dmgURL = downloadedDMGURL else { return }
        
        isInstalling = true
        Task {
            do {
                try await UpdateInstaller.install(artifactURL: dmgURL)
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
