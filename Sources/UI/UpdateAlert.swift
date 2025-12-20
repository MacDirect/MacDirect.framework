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
    @State private var isInstalling: Bool = false
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
                .frame(height: 150) // Maintain layout height
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
                .disabled(isDownloading)
                
                Spacer()
                
                if !isDownloading && !isInstalling {
                    Button("Remind Me Later") {
                        NSApp.keyWindow?.close()
                    }
                    
                    Button("Install Update") {
                        startUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        // Cancel logic (not implemented in DownloadManager yet)
                        NSApp.keyWindow?.close()
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 320)
    }
    
    private func startUpdate() {
        let url = update.downloadURL
        isDownloading = true
        errorMessage = nil
        
        Task {
            do {
                let dmgLocation = try await downloadManager.downloadUpdate(from: url)
                
                await MainActor.run {
                    isDownloading = false
                    isInstalling = true
                }
                
                try await UpdateInstaller.install(dmgURL: dmgLocation)
                // App should restart here
            } catch {
                await MainActor.run {
                    isDownloading = false
                    isInstalling = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
