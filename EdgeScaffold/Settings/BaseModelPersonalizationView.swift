// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeUI

struct BaseModelPersonalizationView: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @State private var isLoadingModel = false

    var body: some View {
        List {
            Section("Model Runtime") {
                infoRow("Status", runtimeStatus)
                infoRow("Model", aiManager.loadedModelName ?? ScaffoldConfig.modelDisplayName)
                infoRow("Type", aiManager.modelCategory.rawValue.uppercased())
                if aiManager.isModelLoaded {
                    infoRow("Source", aiManager.loadSource.rawValue)
                }

                if !aiManager.isModelLoaded {
                    Button {
                        loadModel()
                    } label: {
                        Label(isLoadingModel ? "Loading model..." : "Load Local Model", systemImage: "cpu")
                    }
                    .disabled(isLoadingModel || aiManager.engineState == .loading)
                }

                Text("Detailed model download, path diagnostics, and AI engine controls stay in Settings → AI Engine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Neural Imprint Restore") {
                Toggle("Restore Neural Imprint", isOn: Binding(
                    get: { aiManager.isNeuralImprintRestoreEnabled },
                    set: { enabled in
                        aiManager.setNeuralImprintRestoreEnabled(enabled)
                    }
                ))

                if let status = aiManager.neuralImprintCacheStatus {
                    infoRow("Status", "Active")
                        .edgeDiagnosticTapGesture()
                    if diagnostics.isDetailedMetricsEnabled {
                        infoRow("Prefix Tokens", "\(status.prefixTokenCount)")
                        infoRow("Artifact", String(status.artifactSHA256.prefix(12)))
                    }
                } else if let error = aiManager.neuralImprintCacheError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    infoRow("Status", aiManager.isNeuralImprintRestoreEnabled ? "Not active" : "Disabled")
                }
            }

            Section("A/B Smoke") {
                NavigationLink {
                    PersonaABTestView()
                } label: {
                    Label("Open Neural Imprint A/B Smoke", systemImage: "arrow.left.arrow.right.circle")
                }
                Text("Use the same prompt against base model and Neural Imprint restore. This page should not inject profile text into system prompt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Base Model")
    }

    private var runtimeStatus: String {
        switch aiManager.engineState {
        case .ready: return "Ready"
        case .loading: return "Loading..."
        case .generating: return "Generating..."
        case .idle: return "Idle"
        }
    }

    private func loadModel() {
        isLoadingModel = true
        Task { @MainActor in
            await aiManager.loadSelectedModel()
            isLoadingModel = false
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
