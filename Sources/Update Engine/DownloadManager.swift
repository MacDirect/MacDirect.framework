//
//  DownloadManager.swift
//  MacDirect.framework
//
//  Created by Bregas Satria Wicaksono on 14/12/25.
//

import Foundation
import Combine
import AppKit
import CryptoKit

@MainActor
final class DownloadManager: NSObject, URLSessionDownloadDelegate, ObservableObject {
    @Published var progress: Double = 0.0
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    
    // Thread-safe storage for checksum
    private class ChecksumState: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }
    private let checksumState = ChecksumState()
    
    // Shared instance for simplicity in this MVP context, though normally we'd inject.
    static let shared = DownloadManager()
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func downloadUpdate(from url: URL, checksum: String? = nil) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.checksumState.value = checksum
            
            if let resumeData = self.resumeData {
                print("Resuming download...")
                self.downloadTask = session.downloadTask(withResumeData: resumeData)
                self.resumeData = nil // Consumed
            } else {
                print("Starting new download from \(url)")
                self.downloadTask = session.downloadTask(with: url)
            }
            
            self.downloadTask?.resume()
        }
    }
    
    func cancelDownload() {
        print("Cancelling download...")
        self.downloadTask?.cancel(byProducingResumeData: { data in
            if let data = data {
                print("Resume data produced: \(data.count) bytes")
                self.resumeData = data
            }
        })
        // We also need to fail the continuation if it's pending?
        // Or will didCompleteWithError be called?
        // cancel delegates to didCompleteWithError with NSURLErrorCancelled
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a permanent temporary location so it doesn't get deleted immediately
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent(downloadTask.response?.suggestedFilename ?? "update.dmg")
        
        do {
            // Verify Checksum if needed
            if let expected = checksumState.value {
                let fileData = try Data(contentsOf: location)
                let digest = SHA256.hash(data: fileData)
                let calculated = digest.compactMap { String(format: "%02x", $0) }.joined()
                
                if calculated != expected {
                    throw NSError(domain: "DownloadManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch. Expected \(expected), got \(calculated)."])
                }
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            Task { @MainActor in
                self.continuation?.resume(returning: destinationURL)
                self.continuation = nil
                self.checksumState.value = nil
            }
        } catch {
            Task { @MainActor in
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                self.checksumState.value = nil
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
            // Check if cancelled
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                // Determine if we should throw or just stay silent?
                // The continuation needs to be finished.
                Task { @MainActor in
                    self.continuation?.resume(throwing: error)
                    self.continuation = nil
                }
            } else {
                Task { @MainActor in
                    self.continuation?.resume(throwing: error)
                    self.continuation = nil
                }
            }
        }
    }
}

// MARK: - Update Installer


