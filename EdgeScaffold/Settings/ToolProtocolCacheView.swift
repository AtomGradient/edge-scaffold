// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeUI

struct ToolProtocolCacheView: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared

    @State private var toolSchemaSnapshot: ToolSchemaSnapshot?
    @State private var toolSchemaError: String?
    @State private var captureStage: ToolProtocolCaptureStage = .idle
    @State private var captureStartedAt: Date?
    @State private var captureStatus: String?
    @State private var captureError: String?
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            Section {
                FeatureGuideHeader(
                    icon: "wrench.and.screwdriver.fill",
                    title: "Tool Protocol Learning",
                    description: "Inspect and capture the read-only sample tool protocol into KV states. This teaches the model the tool interface; it is not a user profile.",
                    steps: [
                        .init(number: 1, action: "Register app-owned read-only tools", api: "ToolRegistry.register(...)"),
                        .init(number: 2, action: "Export canonical tool schema", api: "ToolRegistry.toolSchemaSnapshot()"),
                        .init(number: 3, action: "Capture combined Neural Imprint", api: "RPP profile + tool schema priming"),
                        .init(number: 4, action: "Let Chat execute model-selected tools", api: "ToolChatLoop + ToolRegistry"),
                    ],
                    developerNote: "Chat does not pass live tool schemas before Neural Imprint is active. User Profile (RPP) builds a richer combined artifact that includes profile and tool protocol KV. Tools-only KV is only the smaller bootstrap path when no combined Neural Imprint exists."
                )
            }

            Section("Registered Tools") {
                SampleDomainMiniHeader(domain: selectedDomain)

                if let snapshot = toolSchemaSnapshot {
                    infoRow("Tools", "\(snapshot.export.tools.count)")
                    infoRow("Schema SHA256", String(snapshot.sha256.prefix(12)))

                    ForEach(snapshot.export.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool.name)
                                .font(.subheadline.bold())
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } else if let toolSchemaError {
                    Label(toolSchemaError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("No tool schema snapshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tools-only KV") {
                Button {
                    captureToolsOnlyKV()
                } label: {
                    Label(
                        toolsOnlyButtonTitle,
                        systemImage: "bolt.badge.automatic"
                    )
                }
                .disabled(
                    isCapturingToolsOnlyKV
                        || !aiManager.isModelLoaded
                        || aiManager.hasNeuralImprintCache
                        || !hasToolSchema
                )

                if isCapturingToolsOnlyKV || captureStage == .done || captureStage == .failed {
                    toolLearningProgress
                }

                if aiManager.hasNeuralImprintCache, let status = aiManager.neuralImprintCacheStatus {
                    Label(
                        diagnostics.isDetailedMetricsEnabled
                            ? "Tool protocol included in active combined Neural Imprint (\(status.prefixTokenCount) prefix tokens). Tools-only KV is not needed."
                            : "Tool protocol included in active Neural Imprint. Tools-only KV is not needed.",
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.green)
                        .edgeDiagnosticTapGesture()
                } else if !aiManager.isModelLoaded {
                    Label("Load the model before capturing tool protocol KV.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let captureStatus {
                    Label(captureStatus, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let captureError {
                    Label(captureError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("This captures only the registered tool protocol into KV states. It is not a user profile. If User Profile (RPP) has already activated combined Neural Imprint, that artifact supersedes tools-only KV.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let json = toolSchemaSnapshot?.jsonString {
                Section {
                    ShareLink(item: json) {
                        Label("Share Tool Schema JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Tool Protocol")
        .task {
            refreshToolSchemaSnapshot()
        }
        .onChange(of: selectedDomainRawValue) { _, _ in
            refreshToolSchemaSnapshot()
        }
    }

    private func refreshToolSchemaSnapshot() {
        do {
            toolSchemaSnapshot = try AIManager.neuralImprintToolSchemaSnapshot()
            toolSchemaError = nil
        } catch {
            toolSchemaSnapshot = nil
            toolSchemaError = error.localizedDescription
        }
    }

    private var hasToolSchema: Bool {
        !(toolSchemaSnapshot?.export.tools.isEmpty ?? true)
    }

    private var isCapturingToolsOnlyKV: Bool {
        captureStage == .validating || captureStage == .capturing
    }

    private var toolsOnlyButtonTitle: String {
        if aiManager.hasNeuralImprintCache {
            return "Covered by Neural Imprint"
        }
        if isCapturingToolsOnlyKV {
            return "Learning tool protocol..."
        }
        return "Generate Tools-only KV"
    }

    private func captureToolsOnlyKV() {
        guard !isCapturingToolsOnlyKV else { return }
        captureStage = .validating
        captureStartedAt = Date()
        captureStatus = nil
        captureError = nil
        Task { @MainActor in
            do {
                refreshToolSchemaSnapshot()
                guard hasToolSchema else {
                    captureStage = .failed
                    captureStartedAt = nil
                    captureError = toolSchemaError ?? "No registered tools found."
                    return
                }
                captureStage = .capturing
                let status = try await aiManager.buildAndActivateToolsOnlyNeuralImprint()
                captureStage = .done
                captureStartedAt = nil
                captureStatus = diagnostics.isDetailedMetricsEnabled
                    ? "Tools-only KV active: \(status.prefixTokenCount) prefix tokens"
                    : "Tools-only Neural Imprint active"
            } catch {
                captureStage = .failed
                captureStartedAt = nil
                captureError = error.localizedDescription
            }
        }
    }

    private var toolLearningProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCapturingToolsOnlyKV {
                EdgeActivityStatusView(
                    status: captureStage.activityStatus,
                    startedAt: captureStartedAt,
                    compact: false,
                    metricLabel: captureStage.shortStatus,
                    isActive: true,
                    accentColor: .orange,
                    motion: .lightweight
                )
            }

            HStack {
                Text(captureStage.title)
                    .font(.subheadline.bold())
                Spacer()
                Text(captureStage.shortStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let progress = captureStage.progress {
                ProgressView(value: progress)
                    .tint(captureStage == .failed ? .red : .orange)
            } else {
                ProgressView()
                    .tint(.orange)
            }

            HStack(spacing: 12) {
                toolStageDot(.validating)
                toolStageDot(.capturing)
                toolStageDot(.done)
            }

            Text(captureStage.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func toolStageDot(_ stage: ToolProtocolCaptureStage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: captureStage.icon(for: stage))
                .foregroundStyle(captureStage.color(for: stage))
            Text(stage.timelineLabel)
                .font(.caption2)
                .foregroundStyle(captureStage.color(for: stage))
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

private enum ToolProtocolCaptureStage: Equatable {
    case idle
    case validating
    case capturing
    case done
    case failed

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .validating: return "Validating tools"
        case .capturing: return "Capturing KV"
        case .done: return "Tool protocol active"
        case .failed: return "Learning failed"
        }
    }

    var shortStatus: String {
        switch self {
        case .idle: return "idle"
        case .validating: return "1/3"
        case .capturing: return "2/3"
        case .done: return "done"
        case .failed: return "error"
        }
    }

    var timelineLabel: String {
        switch self {
        case .idle: return "Idle"
        case .validating: return "Validate"
        case .capturing: return "Capture"
        case .done: return "Active"
        case .failed: return "Error"
        }
    }

    var progress: Double? {
        switch self {
        case .idle: return 0
        case .validating: return 0.2
        case .capturing: return nil
        case .done: return 1
        case .failed: return 1
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Load a model and register tools before capture."
        case .validating:
            return "Checking registered sample tools and exported schema hash."
        case .capturing:
            return "Running the model prefill and saving the tool protocol KV artifact."
        case .done:
            return "The active KV now contains the registered tool protocol."
        case .failed:
            return "The artifact was not activated. Check the error below and try again."
        }
    }

    var activityStatus: EdgeActivityStatus {
        EdgeActivityStatus(
            title: title,
            detail: detail,
            systemImage: "bolt.badge.automatic",
            actionLabel: title
        )
    }

    func icon(for stage: ToolProtocolCaptureStage) -> String {
        if self == .failed, stage == .capturing { return "xmark.circle.fill" }
        if order(of: stage) < order(of: self) || self == .done && stage == .done {
            return "checkmark.circle.fill"
        }
        if stage == self {
            return "circle.dotted"
        }
        return "circle"
    }

    func color(for stage: ToolProtocolCaptureStage) -> Color {
        if self == .failed, stage == .capturing { return .red }
        if order(of: stage) < order(of: self) || self == .done && stage == .done {
            return .green
        }
        if stage == self {
            return .orange
        }
        return .secondary
    }

    private func order(of stage: ToolProtocolCaptureStage) -> Int {
        switch stage {
        case .idle: return 0
        case .validating: return 1
        case .capturing: return 2
        case .done: return 3
        case .failed: return 2
        }
    }
}
