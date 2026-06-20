// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeUI

struct AIEngineSection: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @State private var modelPathDiagnostic = AIManager.validateDocumentsModelInstall()

    var body: some View {
        Section("AI Engine") {
            Toggle("On-Device AI", isOn: Binding(
                get: { aiManager.stateManager.isAIEnabled },
                set: { newValue in
                    aiManager.stateManager.isAIEnabled = newValue
                    if !newValue {
                        aiManager.unloadModel()
                    } else if aiManager.stateManager.isModelDownloaded {
                        Task { await aiManager.loadSelectedModel() }
                    }
                }
            ))

            if aiManager.stateManager.isAIEnabled {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                if let name = aiManager.loadedModelName {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(name)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(aiManager.modelCategory.rawValue.uppercased())
                            .foregroundStyle(.secondary)
                    }
                }

                if aiManager.isModelLoaded {
                    HStack {
                        Text("Source")
                        Spacer()
                        Text(aiManager.loadSource.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }

                if modelPathDiagnostic.isActionable {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Model install path", systemImage: "folder.badge.questionmark")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text(modelPathDiagnostic.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !modelPathDiagnostic.misplacedRootFiles.isEmpty {
                            let rootFiles = modelPathDiagnostic.misplacedRootFiles.prefix(3).joined(separator: ", ")
                            Text("Root files: \(rootFiles)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if aiManager.engineState == .loading {
                    ProgressView(value: aiManager.loadingProgress)
                        .progressViewStyle(.linear)
                }

                Toggle("Neural Imprint Restore", isOn: Binding(
                    get: { aiManager.isNeuralImprintRestoreEnabled },
                    set: { enabled in
                        aiManager.setNeuralImprintRestoreEnabled(enabled)
                    }
                ))

                if let status = aiManager.neuralImprintCacheStatus {
                    HStack {
                        Text("Neural Imprint")
                        Spacer()
                        Text(diagnostics.isDetailedMetricsEnabled
                             ? "\(status.prefixTokenCount) prefix tokens"
                             : "active")
                            .foregroundStyle(.secondary)
                            .edgeDiagnosticTapGesture()
                    }
                } else if let error = aiManager.neuralImprintCacheError {
                    HStack {
                        Text("Neural Imprint")
                        Spacer()
                        Text(error)
                            .lineLimit(1)
                            .foregroundStyle(.red)
                    }
                } else {
                    HStack {
                        Text("Neural Imprint")
                        Spacer()
                        Text(aiManager.isNeuralImprintRestoreEnabled ? "Not active" : "Disabled")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            modelPathDiagnostic = AIManager.validateDocumentsModelInstall()
        }
        .onChange(of: aiManager.engineState) {
            modelPathDiagnostic = AIManager.validateDocumentsModelInstall()
        }
    }

    private var statusColor: Color {
        switch aiManager.engineState {
        case .ready: .green
        case .loading: .orange
        case .generating: .blue
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch aiManager.engineState {
        case .ready: "Ready"
        case .loading: "Loading..."
        case .generating: "Generating..."
        case .idle: "Idle"
        }
    }
}
