// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData
import EdgeInference
import EdgeUI
#if canImport(UIKit)
import UIKit
#endif

struct PersonalizationHubView: View {
    @EnvironmentObject private var aiManager: AIManager
    @EnvironmentObject private var meshManager: MeshManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @ObservedObject private var rppManager = RPPSelfLearningManager.shared

    @State private var classifiedCount: Int = 0
    @State private var rawCount: Int = 0
    @State private var isLoadingModel = false
    @State private var isSeedingFacts = false
    @State private var isCapturingToolsOnlyKV = false
    @State private var actionMessage: String?
    @State private var actionError: String?
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            SampleDomainPickerSection(
                selectedDomainRawValue: $selectedDomainRawValue,
                onDomainActivated: {
                    refreshStats()
                }
            )

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Neural Imprint Developer Journey", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.indigo)

                    Text("Follow the model as it gets more capable: plain chat, tool protocol learning, profile learning, then correction-driven relearning. Runtime prompts stay minimal; capability comes from restored KV states.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    JourneyStageCard(
                        number: 1,
                        title: "Base Model",
                        subtitle: "Plain local chat. No tool schema and no profile are restored.",
                        status: aiManager.isModelLoaded ? .done : .notStarted,
                        prompts: [
                            "我上个月餐饮花了多少钱？",
                            "帮我查一下上次在星巴克的消费",
                        ]
                    )

                    JourneyStageCard(
                        number: 2,
                        title: "Tool Protocol Learning",
                        subtitle: "Seed sample facts, capture tools-only KV, then let the model choose \(selectedDomain.displayName) tools.",
                        status: aiManager.hasNeuralImprintCache ? .done : sampleDataStatus,
                        prompts: selectedDomain.toolPromptExamples
                    )

                    JourneyStageCard(
                        number: 3,
                        title: "User Profile Learning",
                        subtitle: "Run RPP and capture a combined Neural Imprint containing profile + tool protocol.",
                        status: rppManager.lastOutput != nil && aiManager.hasNeuralImprintCache ? .ready : rppStatus,
                        prompts: selectedDomain.profilePromptExamples
                    )

                    JourneyStageCard(
                        number: 4,
                        title: "Correction Learning",
                        subtitle: "Review classifications, collect corrections, then relearn the profile.",
                        status: classificationStatus,
                        prompts: [
                            "我最近有没有新的消费模式？",
                            "同类记录以后应该怎么分类？",
                        ]
                    )
                }
                .padding(.vertical, 4)
            }

            Section("Stage Actions") {
                Button {
                    loadLocalModel()
                } label: {
                    Label(
                        isLoadingModel ? "Loading model..." : "Load Local Model",
                        systemImage: "cpu"
                    )
                }
                .disabled(isLoadingModel || aiManager.isModelLoaded)

                Button {
                    seedClassifiedFacts()
                } label: {
                    Label(
                        isSeedingFacts ? "Seeding sample facts..." : "Seed Classified Demo Facts",
                        systemImage: "checkmark.seal.fill"
                    )
                }
                .disabled(isSeedingFacts)

                Button {
                    captureToolsOnlyKV()
                } label: {
                    Label(
                        isCapturingToolsOnlyKV ? "Capturing tools-only KV..." : "Generate Tools-only KV",
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                }
                .disabled(
                    isCapturingToolsOnlyKV
                        || !aiManager.isModelLoaded
                        || aiManager.hasNeuralImprintCache
                )

                Button {
                    rppManager.start(aiManager: aiManager)
                } label: {
                    Label(
                        rppManager.isRunning ? "RPP learning..." : "Run User Profile (RPP)",
                        systemImage: "brain.head.profile.fill"
                    )
                }
                .disabled(rppManager.isRunning || !aiManager.isModelLoaded || classifiedCount == 0)

                if let actionMessage {
                    Label(actionMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Checklist") {
                ChecklistRow(
                    index: 1,
                    title: "Seed classified sample facts",
                    detail: classifiedCount > 0
                        ? "\(classifiedCount) sample facts ready"
                        : "Start with synthetic local facts; no private dogfood data is bundled.",
                    status: sampleDataStatus
                )
                ChecklistRow(
                    index: 2,
                    title: "Load local model",
                    detail: aiManager.isModelLoaded
                        ? (aiManager.loadedModelName ?? ScaffoldConfig.modelID)
                        : "Load the model before RPP or Neural Imprint capture.",
                    status: aiManager.isModelLoaded ? .done : .notStarted
                )
                ChecklistRow(
                    index: 3,
                    title: "Run User Profile (RPP)",
                    detail: rppManager.isRunning
                        ? rppManager.stageDetail
                        : (rppManager.lastOutput == nil ? "RPP builds the profile source from sample facts." : "RPP output is ready."),
                    status: rppStatus
                )
                ChecklistRow(
                    index: 4,
                    title: "Activate combined Neural Imprint",
                    detail: aiManager.hasNeuralImprintCache
                        ? "Neural Imprint active: profile + tool protocol are in restored KV states."
                        : "RPP completion should capture and restore the combined Neural Imprint.",
                    status: smokeStatus
                )
                ChecklistRow(
                    index: 5,
                    title: "Ask in Chat",
                    detail: aiManager.hasNeuralImprintCache
                        ? "Chat may now allow autonomous tool_call from the KV-learned protocol."
                        : "Before Neural Imprint is active, Chat stays plain and does not pass tool schemas.",
                    status: aiManager.hasNeuralImprintCache ? .ready : .notStarted
                )
            }

            Section("Advanced Details") {
                NavigationLink {
                    SampleDataView()
                } label: {
                    FeatureRow(
                        icon: "shippingbox.fill",
                        color: .cyan,
                        title: "Sample Data",
                        subtitle: rawCount + classifiedCount > 0
                            ? "\(classifiedCount) classified, \(rawCount) raw"
                            : "Seed synthetic \(selectedDomain.displayName.lowercased()) records",
                        badge: sampleDataStatus
                    )
                }

                NavigationLink {
                    ClassificationDemoView()
                } label: {
                    FeatureRow(
                        icon: "tag.fill",
                        color: .teal,
                        title: "Classification Review / Correction Inbox",
                        subtitle: classifiedCount > 0
                            ? "\(classifiedCount) classified, \(rawCount) pending"
                            : "Classify and correct synthetic facts",
                        badge: classificationStatus
                    )
                }

                NavigationLink {
                    PersonalizationView()
                } label: {
                    FeatureRow(
                        icon: "arrow.triangle.2.circlepath.circle.fill",
                        color: .blue,
                        title: "Data Pipeline / Correction Learning",
                        subtitle: "Raw/classified totals, feedback, mesh sync",
                        badge: sampleDataStatus
                    )
                }

                NavigationLink {
                    RPPSelfLearningView()
                } label: {
                    FeatureRow(
                        icon: "brain.head.profile.fill",
                        color: .indigo,
                        title: "User Profile (RPP)",
                        subtitle: "Profile refresh readiness + on-device RPP",
                        badge: rppStatus
                    )
                }

                NavigationLink {
                    ToolProtocolCacheView()
                } label: {
                    FeatureRow(
                        icon: "wrench.and.screwdriver.fill",
                        color: .orange,
                        title: "Tool Protocol Cache",
                        subtitle: "Registered read-only sample tools + schema hash",
                        badge: .ready
                    )
                }

                NavigationLink {
                    PersonaABTestView()
                } label: {
                    FeatureRow(
                        icon: "arrow.left.arrow.right.circle",
                        color: .purple,
                        title: "Neural Imprint A/B Smoke",
                        subtitle: "Persona probes + controls",
                        badge: smokeStatus
                    )
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Getting Started", systemImage: "hammer.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 6) {
                        guideStep(1, "Seed **Sample Data** as classified facts for a fast RPP/tool demo")
                        guideStep(2, "Use **Classification Review** to see raw → classified and correction flow")
                        guideStep(3, "Run **User Profile (RPP)** to generate a user profile")
                        guideStep(4, "Use **Neural Imprint A/B Smoke** and Chat to compare base vs persona restore")
                    }

                    Text("For your own app: replace the synthetic records provider, keep app-owned business mapping outside edge-kit, and expose your read-only tools through ToolRegistry.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Developer Guide")
            }
        }
        .navigationTitle("AI Personalization")
        .onAppear { refreshStats() }
        .onChange(of: selectedDomainRawValue) { _, _ in
            refreshStats()
        }
    }


    private var sampleDataStatus: StepStatus {
        if classifiedCount > 0 { return .done }
        if rawCount > 0 { return .inProgress }
        return .notStarted
    }

    private var classificationStatus: StepStatus {
        if classifiedCount > 0 { return .done }
        if rawCount > 0 { return .inProgress }
        return .notStarted
    }

    private var meshStatus: StepStatus {
        if meshManager.isEnabled && !meshManager.trustedPeers.filter({ !$0.revoked }).isEmpty {
            return .done
        }
        if meshManager.isEnabled { return .inProgress }
        return .notStarted
    }

    private var rppStatus: StepStatus {
        if rppManager.lastOutput != nil { return .done }
        if rppManager.isRunning { return .inProgress }
        return .notStarted
    }

    private var smokeStatus: StepStatus {
        if aiManager.hasNeuralImprintCache { return .ready }
        return .notStarted
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
    }

    private func loadLocalModel() {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        actionMessage = nil
        actionError = nil
        Task { @MainActor in
            await aiManager.loadSelectedModel()
            if aiManager.isModelLoaded {
                actionMessage = "Model loaded: \(aiManager.loadedModelName ?? ScaffoldConfig.modelID)"
            } else {
                actionError = aiManager.loadError ?? "Model load failed"
            }
            isLoadingModel = false
        }
    }

    private func seedClassifiedFacts() {
        guard !isSeedingFacts else { return }
        isSeedingFacts = true
        actionMessage = nil
        actionError = nil
        Task { @MainActor in
            do {
                let result = try selectedDomain.seedClassifiedFacts()
                actionMessage = "Seeded \(result.writtenThisRun) records. Total facts: \(result.total)."
                refreshStats()
            } catch {
                actionError = error.localizedDescription
            }
            isSeedingFacts = false
        }
    }

    private func captureToolsOnlyKV() {
        guard !isCapturingToolsOnlyKV else { return }
        isCapturingToolsOnlyKV = true
        actionMessage = nil
        actionError = nil
        Task { @MainActor in
            do {
                let status = try await aiManager.buildAndActivateToolsOnlyNeuralImprint()
                actionMessage = diagnostics.isDetailedMetricsEnabled
                    ? "Tools-only KV active: \(status.prefixTokenCount) prefix tokens"
                    : "Tools-only Neural Imprint active"
            } catch {
                actionError = error.localizedDescription
            }
            isCapturingToolsOnlyKV = false
        }
    }

    @ViewBuilder
    private func guideStep(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).")
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text(text)
                .font(.caption)
        }
    }
}


enum StepStatus {
    case notStarted, inProgress, done, ready
}

private struct ChecklistRow: View {
    let index: Int
    let title: String
    let detail: String
    let status: StepStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(statusColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            statusBadge
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch status {
        case .notStarted: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .ready: return .purple
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .notStarted:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView().scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .ready:
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.purple)
        }
    }
}

private struct JourneyStageCard: View {
    let number: Int
    let title: String
    let subtitle: String
    let status: StepStatus
    let prompts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(color))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                statusLabel
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Preset prompts")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        copyPrompt(prompt)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\"\(prompt)\"")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.04), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 34)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch status {
        case .notStarted: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .ready: return .purple
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .notStarted:
            Text("start")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .inProgress:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.55)
                Text("running")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .done:
            Label("done", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .ready:
            Label("active", systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(.purple)
        }
    }

    private func copyPrompt(_ prompt: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = prompt
        #endif
    }
}

private struct PipelineStepRow: View {
    let number: String
    let title: String
    let subtitle: String
    let status: StepStatus
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .notStarted:
            Text("—")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .inProgress:
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.5)
                Text("...")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .ready:
            Text("ready")
                .font(.caption2)
                .foregroundStyle(.purple)
        }
    }
}

private struct PipelineArrow: View {
    var body: some View {
        HStack {
            Spacer().frame(width: 10)
            Image(systemName: "arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}


private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let badge: StepStatus

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch badge {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .inProgress:
                ProgressView().scaleEffect(0.5)
            case .ready:
                Text("ready")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            case .notStarted:
                EmptyView()
            }
        }
    }
}
