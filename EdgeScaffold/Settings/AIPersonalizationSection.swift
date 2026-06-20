// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData
import EdgeInference
import EdgeUI

struct AIPersonalizationSection: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @ObservedObject private var rppManager = RPPSelfLearningManager.shared
    @StateObject private var personalization = PersonalizationManager.shared

    @State private var classifiedCount = 0
    @State private var rawCount = 0
    @State private var classificationCorrectionCount = 0
    @State private var toolCount = 0
    @State private var toolSchemaError: String?
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        Section("AI Personalization") {
            NavigationLink {
                BaseModelPersonalizationView()
            } label: {
                personalizationRow(
                    icon: "cpu",
                    color: .blue,
                    title: "Base Model",
                    subtitle: baseModelSubtitle,
                    status: baseModelStatus,
                    enablesDiagnosticGesture: aiManager.hasNeuralImprintCache
                )
            }

            NavigationLink {
                ToolProtocolCacheView()
            } label: {
                personalizationRow(
                    icon: "wrench.and.screwdriver.fill",
                    color: .orange,
                    title: "Tool Protocol Learning",
                    subtitle: toolProtocolSubtitle,
                    status: toolProtocolStatus
                )
            }

            NavigationLink {
                RPPSelfLearningView()
            } label: {
                personalizationRow(
                    icon: "brain.head.profile.fill",
                    color: .indigo,
                    title: "User Profile Learning",
                    subtitle: userProfileSubtitle,
                    status: userProfileStatus
                )
            }

            NavigationLink {
                CorrectionLearningView()
            } label: {
                personalizationRow(
                    icon: "checklist.checked",
                    color: .teal,
                    title: "Correction Learning",
                    subtitle: correctionSubtitle,
                    status: correctionStatus
                )
            }
        }
        .task {
            refreshStats()
        }
        .onChange(of: selectedDomainRawValue) { _, _ in
            refreshStats()
        }
    }

    private var baseModelSubtitle: String {
        if let status = aiManager.neuralImprintCacheStatus {
            return diagnostics.isDetailedMetricsEnabled
                ? "Neural Imprint active · \(status.prefixTokenCount) prefix tokens"
                : "Neural Imprint · active"
        }
        if aiManager.isModelLoaded {
            return aiManager.loadedModelName ?? ScaffoldConfig.modelDisplayName
        }
        return "Load model and inspect restore state"
    }

    private var baseModelStatus: PersonalizationModuleStatus {
        if aiManager.hasNeuralImprintCache { return .active }
        if aiManager.isModelLoaded { return .ready }
        return .needsSetup
    }

    private var toolProtocolSubtitle: String {
        if aiManager.hasNeuralImprintCache {
            return "Included in active combined Neural Imprint"
        }
        if let toolSchemaError {
            return toolSchemaError
        }
        if toolCount > 0 {
            return "\(toolCount) \(selectedDomain.displayName) tools registered"
        }
        return "Register tools, capture tools-only KV"
    }

    private var toolProtocolStatus: PersonalizationModuleStatus {
        if aiManager.hasNeuralImprintCache { return .active }
        if toolCount > 0 && aiManager.isModelLoaded { return .ready }
        if toolCount > 0 { return .needsModel }
        return .needsSetup
    }

    private var userProfileSubtitle: String {
        if rppManager.isRunning {
            return rppManager.stage.displayName
        }
        if rppManager.lastOutput != nil, aiManager.hasNeuralImprintCache {
            return "Profile learned and Neural Imprint active"
        }
        if rppManager.lastOutput != nil {
            return "RPP output ready · activate Neural Imprint"
        }
        if classifiedCount > 0 {
            return "\(classifiedCount) \(selectedDomain.displayName) facts ready"
        }
        return "Seed sample facts, then run RPP"
    }

    private var userProfileStatus: PersonalizationModuleStatus {
        if rppManager.isRunning { return .running }
        if rppManager.lastOutput != nil && aiManager.hasNeuralImprintCache { return .active }
        if classifiedCount > 0 && aiManager.isModelLoaded { return .ready }
        if classifiedCount > 0 { return .needsModel }
        return .needsSetup
    }

    private var correctionSubtitle: String {
        let totalCorrections = classificationCorrectionCount + personalization.correctionCount
        if totalCorrections > 0 {
            return "\(totalCorrections) correction signals · \(classifiedCount) facts"
        }
        if classifiedCount > 0 || rawCount > 0 {
            return "Review classifications and feed relearning"
        }
        return "Seed sample data to review corrections"
    }

    private var correctionStatus: PersonalizationModuleStatus {
        let totalCorrections = classificationCorrectionCount + personalization.correctionCount
        if totalCorrections > 0 { return .ready }
        if classifiedCount > 0 || rawCount > 0 { return .needsReview }
        return .needsSetup
    }

    private func refreshStats() {
        guard EdgeDataBootstrap.isReady else { return }
        classifiedCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .classifiedOnly
        )) ?? 0
        rawCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .rawUnclassified
        )) ?? 0
        let facts = (try? Edge.queryFacts(
            namespace: selectedDomain.namespace,
            status: .all,
            limit: 1_000
        )) ?? []
        classificationCorrectionCount = facts.filter { $0.classificationCorrectedAt != nil }.count

        do {
            let snapshot = try AIManager.neuralImprintToolSchemaSnapshot()
            toolCount = snapshot.export.tools.count
            toolSchemaError = nil
        } catch {
            toolCount = 0
            toolSchemaError = error.localizedDescription
        }
    }

    private func personalizationRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        status: PersonalizationModuleStatus,
        enablesDiagnosticGesture: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                let subtitleText = Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if enablesDiagnosticGesture {
                    subtitleText.edgeDiagnosticTapGesture()
                } else {
                    subtitleText
                }
            }
            Spacer(minLength: 8)
            status.badge
        }
        .padding(.vertical, 2)
    }
}

private enum PersonalizationModuleStatus {
    case needsSetup
    case needsModel
    case needsReview
    case ready
    case running
    case active

    @ViewBuilder
    var badge: some View {
        switch self {
        case .needsSetup:
            EmptyView()
        case .needsModel:
            Text("model")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .needsReview:
            Text("review")
                .font(.caption2)
                .foregroundStyle(.teal)
        case .ready:
            Text("ready")
                .font(.caption2)
                .foregroundStyle(.purple)
        case .running:
            ProgressView().scaleEffect(0.55)
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}
