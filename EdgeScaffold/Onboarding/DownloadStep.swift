// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import EdgeModelKit
import SwiftUI

struct DownloadStep: View {
    let onComplete: () -> Void

    @EnvironmentObject private var aiManager: AIManager
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var isDownloading = false
    @State private var downloadComplete = false
    @State private var hasLocalModel = AIManager.isDocumentsModelAvailable()
    @State private var showCellularWarning = false

    private var displayName: String { ScaffoldConfig.modelDisplayName }
    private var sizeGB: Double { ScaffoldConfig.modelSizeGB }
    private var actionTitle: String {
        hasLocalModel ? "Load Local Model" : "Download (\(String(format: "%.1f GB", sizeGB)))"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if downloadComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                Text("Ready to Go!")
                    .font(.title2.bold())

                Text("AI model is loaded and ready.")
                    .foregroundStyle(.secondary)
            } else if isDownloading {
                VStack(spacing: 16) {
                    ProgressView(value: aiManager.loadingProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 40)

                    Text("\(Int(aiManager.loadingProgress * 100))%")
                        .font(.title.monospacedDigit().bold())

                    Text(hasLocalModel ? "Loading \(displayName)..." : "Downloading \(displayName)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if aiManager.loadingProgress > 0.95 && aiManager.loadingProgress < 1.0 {
                        Text("Preparing model for inference...")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Image(systemName: hasLocalModel ? "internaldrive" : "arrow.down.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)

                Text(hasLocalModel ? "Load Local Model" : "Download AI Model")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 12) {
                    infoRow("Model", displayName)
                    infoRow("Size", String(format: "%.1f GB", sizeGB))

                    if hasLocalModel {
                        Label("Found in app Documents", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if !networkMonitor.isConnected {
                        Label("No internet connection", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if networkMonitor.isCellular {
                        Label("Using cellular data", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

                if let error = aiManager.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }
            }

            Spacer()

            if downloadComplete {
                Button(action: onComplete) {
                    Text("Start Using \(ScaffoldConfig.appName)")
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(ChatTheme.userGradient)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
            } else if !isDownloading {
                Button {
                    if hasLocalModel {
                        startDownload()
                    } else if networkMonitor.isCellular {
                        showCellularWarning = true
                    } else {
                        startDownload()
                    }
                } label: {
                    Text(actionTitle)
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background((hasLocalModel || networkMonitor.isConnected) ? ChatTheme.userGradient : LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!hasLocalModel && !networkMonitor.isConnected)
                .padding(.horizontal, 24)

                Button("Skip for Now") {
                    onComplete()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 20)
        }
        .alert("Cellular Data", isPresented: $showCellularWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Download Anyway") { startDownload() }
        } message: {
            Text("This will download \(String(format: "%.1f GB", sizeGB)) over cellular data. Are you sure?")
        }
        .task {
            refreshLocalModelAvailability()
        }
    }

    private func startDownload() {
        refreshLocalModelAvailability()
        isDownloading = true
        Task {
            await aiManager.loadSelectedModel()
            if aiManager.isModelLoaded {
                downloadComplete = true
            }
            isDownloading = false
        }
    }

    private func refreshLocalModelAvailability() {
        hasLocalModel = AIManager.isDocumentsModelAvailable()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
