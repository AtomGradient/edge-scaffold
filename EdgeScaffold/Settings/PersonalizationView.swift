// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData
import EdgeUI

struct PersonalizationView: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @StateObject private var personalization = PersonalizationManager.shared
    @EnvironmentObject private var meshManager: MeshManager

    @State private var classifiedFactCount: Int = 0
    @State private var rawUnclassifiedCount: Int = 0
    @State private var classificationCorrectionCount: Int = 0
    @State private var trainingEventCount: Int = 0
    @State private var lastTrainingExportResult: String?
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Neural Imprint", systemImage: "brain.head.profile")
                        .font(.subheadline)
                    Spacer()
                    if let status = aiManager.neuralImprintCacheStatus {
                        Label(
                            diagnostics.isDetailedMetricsEnabled
                                ? "Active · \(status.prefixTokenCount) tokens"
                                : "Active",
                            systemImage: "checkmark.circle.fill"
                        )
                            .foregroundStyle(.green)
                            .font(.subheadline)
                            .edgeDiagnosticTapGesture()
                    } else {
                        Text("Not active")
                            .foregroundStyle(.secondary)
                    }
                }

                if let status = aiManager.neuralImprintCacheStatus, diagnostics.isDetailedMetricsEnabled {
                    HStack {
                        Text("Artifact")
                        Spacer()
                        Text(status.artifactSHA256.prefix(12))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Backend")
                        Spacer()
                        Text(status.cacheBackend)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else if let error = aiManager.neuralImprintCacheError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            } header: {
                Label("Persona Runtime", systemImage: "3.circle.fill")
            }

            Section {
                HStack {
                    Label("Chat Feedback", systemImage: "hand.thumbsup.fill")
                    Spacer()
                    Text("\(personalization.feedbackCount) samples")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Chat Corrections", systemImage: "pencil.and.list.clipboard")
                    Spacer()
                    Text("\(personalization.correctionCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Classification Corrections", systemImage: "checklist.checked")
                    Spacer()
                    Text("\(classificationCorrectionCount)")
                        .monospacedDigit()
                        .foregroundStyle(classificationCorrectionCount > 0 ? .green : .secondary)
                }
                HStack {
                    Label("Classified Facts", systemImage: "tag.fill")
                    Spacer()
                    Text("\(classifiedFactCount)")
                        .monospacedDigit()
                        .foregroundStyle(classifiedFactCount > 0 ? .green : .secondary)
                }
                HStack {
                    Label("Raw Unclassified", systemImage: "clock.fill")
                    Spacer()
                    Text("\(rawUnclassifiedCount)")
                        .monospacedDigit()
                        .foregroundStyle(rawUnclassifiedCount > 0 ? .orange : .secondary)
                }
                HStack {
                    Label("Training Events", systemImage: "arrow.up.doc.fill")
                    Spacer()
                    Text("\(trainingEventCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Data Pipeline", systemImage: "1.circle.fill")
            }

            Section {
                HStack {
                    Label("Mesh", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text(meshManager.isEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(meshManager.isEnabled ? .green : .secondary)
                }
                HStack {
                    Label("Paired Devices", systemImage: "laptopcomputer")
                    Spacer()
                    let trusted = meshManager.trustedPeers.filter { !$0.revoked }
                    Text("\(trusted.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let runID = meshManager.lastRPPArtifactUploadRunID {
                    HStack {
                        Text("Last RPP Upload")
                        Spacer()
                        Text(runID.prefix(12))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = meshManager.lastRPPArtifactUploadError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Mesh Backflow", systemImage: "2.circle.fill")
            }

            Section("Data Management") {
                Button {
                    exportTrainingData()
                } label: {
                    Label("Export Training JSONL", systemImage: "square.and.arrow.up")
                }
                .disabled(personalization.feedbackCount == 0 && personalization.correctionCount == 0)

                if let lastTrainingExportResult {
                    Text(lastTrainingExportResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    personalization.clearFeedback()
                    lastTrainingExportResult = nil
                    refreshPipelineStats()
                } label: {
                    Label("Clear Feedback and Corrections", systemImage: "trash")
                }
                .disabled(personalization.feedbackCount == 0 && personalization.correctionCount == 0)
            }
        }
        .navigationTitle("Personalization")
        .onAppear {
            refreshPipelineStats()
        }
    }

    private func exportTrainingData() {
        let result = personalization.exportTrainingDataJSONL()
        if result.hasExports {
            let fileNames = result.exportedURLs
                .map(\.lastPathComponent)
                .joined(separator: ", ")
            lastTrainingExportResult = "Exported \(fileNames)"
        } else {
            lastTrainingExportResult = "No feedback or corrections to export"
        }
    }

    private func refreshPipelineStats() {
        guard EdgeDataBootstrap.isReady else { return }
        classifiedFactCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .classifiedOnly
        )) ?? 0
        rawUnclassifiedCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .rawUnclassified
        )) ?? 0
        let facts = (try? Edge.queryFacts(
            namespace: selectedDomain.namespace,
            status: .all,
            limit: 1_000
        )) ?? []
        classificationCorrectionCount = facts.filter { $0.classificationCorrectedAt != nil }.count
        trainingEventCount = EdgeDataBootstrap.trainingSink?.eventStoreCount() ?? 0
    }
}
