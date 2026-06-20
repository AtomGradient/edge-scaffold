// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import Charts
import EdgeData
import EdgeHalo
import EdgeUI

struct RPPSelfLearningView: View {
    @EnvironmentObject private var aiManager: AIManager
    @EnvironmentObject private var meshManager: MeshManager
    @ObservedObject private var manager = RPPSelfLearningManager.shared

    @State private var showExportConfirm = false
    @State private var showShareSheet = false
    @State private var isUploadingToMac = false
    @State private var isUploadingRPPInputToMac = false
    @StateObject private var personalization = PersonalizationManager.shared
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue
    @State private var sampleStats: ScaffoldSampleDomainSeedResult?
    @State private var classificationCorrectionCount = 0
    @State private var isSeedingSampleFacts = false
    @State private var sampleStatus: String?
    @State private var sampleError: String?

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            Section {
                FeatureGuideHeader(
                    icon: "brain.head.profile.fill",
                    title: "On-Device User Profile (RPP)",
                    description: "Extract 4 unique persona directions from your data's hidden states through Imprint Distillation. 30-60 seconds, fully on-device, no cloud.",
                    steps: [
                        .init(number: 1, action: "Load pre-computed direction library", api: "EdgeHalo RPP (directions_a.safetensors)"),
                        .init(number: 2, action: "Forward pass + capture hidden states", api: "LLMEngine/VLMEngine.captureHiddenStates(...)"),
                        .init(number: 3, action: "Imprint Distillation + bootstrap stability test", api: "RPPMath (Accelerate CPU)"),
                        .init(number: 4, action: "Capture + activate combined Neural Imprint", api: "SelfLearningCoordinator + LLMEngine.captureNeuralImprintArtifact(...)"),
                    ],
                    developerNote: "Fork → replace RPPDemoData with real EdgeData facts query. Runtime prompt stays minimal; profile and tool protocol enter the model through the captured Neural Imprint artifact. Exported apps must bind RPP to the model-matched A-library manifest."
                )
            }

            Section {
                SampleDomainMiniHeader(domain: selectedDomain)

                HStack {
                    Label("Classified Facts", systemImage: "tag.fill")
                    Spacer()
                    Text("\(sampleStats?.classified ?? 0)")
                        .monospacedDigit()
                        .foregroundStyle((sampleStats?.classified ?? 0) > 0 ? .green : .secondary)
                }
                HStack {
                    Label("Raw Pending", systemImage: "clock.fill")
                    Spacer()
                    Text("\(sampleStats?.rawUnclassified ?? 0)")
                        .monospacedDigit()
                        .foregroundStyle((sampleStats?.rawUnclassified ?? 0) > 0 ? .orange : .secondary)
                }

                Button {
                    seedClassifiedSampleFacts()
                } label: {
                    Label(
                        isSeedingSampleFacts ? "Seeding sample facts..." : "Seed Classified Demo Facts",
                        systemImage: "checkmark.seal.fill"
                    )
                }
                .disabled(isSeedingSampleFacts || !EdgeDataBootstrap.isReady)

                NavigationLink {
                    SampleDataView()
                } label: {
                    Label("Open Sample Data", systemImage: "shippingbox.fill")
                }

                if isSeedingSampleFacts {
                    HStack {
                        ProgressView()
                        Text("Writing synthetic classified facts...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let sampleStatus {
                    Label(sampleStatus, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let sampleError {
                    Label(sampleError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Sample Data")
            } footer: {
                Text("RPP uses classified facts from the selected sample domain as the profile source. The bundled sample data is synthetic and separate from dogfood.")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = manager.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 4)
                    }

                    HStack(spacing: 12) {
                        Button {
                            manager.start(aiManager: aiManager)
                        } label: {
                            HStack {
                                Image(systemName: manager.isRunning
                                    ? "hourglass" : "sparkles")
                                Text(manager.isRunning
                                    ? "Running..." : "Start User Profile Learning")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .disabled(manager.isRunning || !aiManager.isModelLoaded)

                        if manager.isRunning {
                            Button(role: .destructive) {
                                manager.cancel()
                            } label: {
                                Image(systemName: "stop.circle")
                            }
                        } else if manager.lastOutput != nil {
                            Button {
                                manager.reset()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .tint(.secondary)
                        }
                    }

                    if !aiManager.isModelLoaded {
                        Label("Model not loaded. Load in Settings → AI Engine first.",
                              systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            if manager.lastOutput != nil {
                Section("Profile Refresh Readiness") {
                    if canLearnAgain {
                        Label(refreshReadinessText, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("No new correction signal detected after the last profile run.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Apps should surface this kind of readiness when new corrections, classifications, or enough time have accumulated. EdgeScaffold shows the canonical pattern with sample data.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Mac RPP Input Sample") {
                Button {
                    uploadPersonaRPPInputToMac()
                } label: {
                    Label(
                        isUploadingRPPInputToMac
                            ? "Uploading canonical input..."
                            : "Upload Canonical RPP Input to Mac",
                        systemImage: "arrow.up.doc"
                    )
                }
                .disabled(isUploadingRPPInputToMac)

                if let inputID = meshManager.lastPersonaRPPInputUploadID {
                    Label("Uploaded \(inputID.prefix(12))…", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = meshManager.lastPersonaRPPInputUploadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("This sample exports scaffold demo records as `edgestudio.persona_rpp_input.v1`. Replace the records provider in your app; keep business mapping outside edge-kit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if manager.isRunning || manager.lastOutput != nil
                || manager.lastError != nil
            {
                Section("Progress") {
                    progressSection
                }
            }

            if let output = manager.lastOutput {
                Section("Persona Directions (u_2 .. u_5)") {
                    if output.directions.isEmpty {
                        Text("No stable directions found. (k_selected = \(output.kSelected) — dataset may be too small or dimensions unstable)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(output.directions, id: \.directionKey) { d in
                            DirectionCardView(direction: d)
                        }
                    }
                }

                if !output.scatterPoints.isEmpty {
                    Section("Distribution (\(output.scatterXAxisKey) × \(output.scatterYAxisKey))") {
                        ScatterChartView(
                            points: output.scatterPoints,
                            xKey: output.scatterXAxisKey,
                            yKey: output.scatterYAxisKey
                        )
                    }
                }

                if let narrative = output.profileNarrative,
                   !narrative.isEmpty
                {
                    Section("Profile Summary") {
                        Text(narrative)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Metadata") {
                    HStack {
                        Text("Records Processed")
                        Spacer()
                        Text("\(output.nTransactions)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("k_selected")
                        Spacer()
                        Text("\(output.kSelected) / \(output.bootstrapVerdicts.count)")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Total Time")
                        Spacer()
                        Text(String(format: "%.1f s", output.totalElapsedSeconds))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Bootstrap Stability") {
                        ForEach(output.bootstrapVerdicts, id: \.componentIdx) { v in
                            HStack {
                                let idx = v.componentIdx + 1
                                Text("u_\(idx)")
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(String(
                                    format: "%.3f ± %.3f (>%.2f) %@",
                                    v.meanSimilarity, v.stdSimilarity,
                                    v.threshold, v.pass ? "✓" : "✗"))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(v.pass ? .green : .red)
                            }
                        }
                    }
                    .font(.subheadline)
                }

                if manager.exportFileURL != nil {
                    Section("Export") {
                        Button {
                            uploadRPPArtifactsToMac()
                        } label: {
                            Label(
                                isUploadingToMac ? "Syncing to Mac..." : "Sync RPP to Mac",
                                systemImage: "arrow.up.doc"
                            )
                        }
                        .disabled(isUploadingToMac)

                        if let runID = meshManager.lastRPPArtifactUploadRunID {
                            Label("Synced \(runID.prefix(12))…", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if let error = meshManager.lastRPPArtifactUploadError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            showExportConfirm = true
                        } label: {
                            Label("Export Profile JSON", systemImage: "square.and.arrow.up")
                        }
                        Text("Export full profile (4 direction labels + top transactions + narrative + bootstrap stability) as JSON. Mac sync uses the paired EdgeMesh link.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle("User Profile")
        .alert("Profile contains private data", isPresented: $showExportConfirm) {
            Button("Export", role: .destructive) {
                showShareSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This JSON contains activity amounts, locations, times, and categories. Only share with trusted recipients.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = manager.exportFileURL {
                ActivityViewWrapper(items: [url])
            }
        }
        .task {
            refreshSampleStats()
        }
        .onChange(of: selectedDomainRawValue) { _, _ in
            refreshSampleStats()
        }
    }


    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.isRunning {
                EdgeActivityStatusView(
                    status: rppActivityStatus,
                    startedAt: Date(timeIntervalSinceNow: -manager.elapsedSeconds),
                    compact: false,
                    metricLabel: String(format: "~%.0fs left", manager.estimatedRemainingSeconds),
                    isActive: true,
                    accentColor: .indigo,
                    motion: .lightweight
                )
            }

            HStack {
                Text(manager.stage.displayName)
                    .font(.subheadline.bold())
                Spacer()
                if manager.isRunning && manager.stage != .done {
                    Text(String(format: "%.0fs · ~%.0fs left",
                                manager.elapsedSeconds,
                                manager.estimatedRemainingSeconds))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "%.1fs", manager.elapsedSeconds))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: manager.progressFraction)
                .tint(manager.lastError != nil ? .red : .indigo)

            stageTimeline

            Text(manager.stageDetail.isEmpty ? " " : manager.stageDetail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)

            if manager.datasetSize > 0 {
                Text("Dataset: \(manager.datasetSize) records")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rppActivityStatus: EdgeActivityStatus {
        EdgeActivityStatus(
            title: "Learning profile",
            detail: manager.stageDetail.isEmpty ? manager.stage.displayName : manager.stageDetail,
            systemImage: "brain.head.profile",
            actionLabel: manager.stage.displayName
        )
    }

    private var stageTimeline: some View {
        let visibleStages: [RPPStage] = [
            .loadingALibrary, .templating, .forwarding,
            .pcaAndBootstrap, .naming, .profileNarrative
        ]
        let total = RPPStage.totalBudgetSeconds
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(visibleStages, id: \.self) { s in
                    let weight = max(0, s.expectedSeconds / total)
                    let segWidth = max(8, geo.size.width * weight - 2)
                    StageSegment(
                        stage: s,
                        currentStage: manager.stage,
                        hasError: manager.lastError != nil
                    )
                    .frame(width: segWidth)
                }
            }
        }
        .frame(height: 22)
    }

    private func uploadRPPArtifactsToMac() {
        guard !isUploadingToMac else { return }
        isUploadingToMac = true
        Task { @MainActor in
            do {
                _ = try await meshManager.uploadLatestRPPArtifactsToMac()
            } catch {
                meshManager.lastRPPArtifactUploadError = error.localizedDescription
            }
            isUploadingToMac = false
        }
    }

    private func uploadPersonaRPPInputToMac() {
        guard !isUploadingRPPInputToMac else { return }
        isUploadingRPPInputToMac = true
        Task { @MainActor in
            do {
                _ = try await meshManager.uploadPersonaRPPInputToMac()
            } catch {
                meshManager.lastPersonaRPPInputUploadError = error.localizedDescription
            }
            isUploadingRPPInputToMac = false
        }
    }

    private var canLearnAgain: Bool {
        classificationCorrectionCount > 0
            || personalization.correctionCount > 0
            || personalization.feedbackCount > 0
    }

    private var refreshReadinessText: String {
        let corrections = classificationCorrectionCount + personalization.correctionCount
        return "Profile can learn again: \(corrections) corrections, \(sampleStats?.classified ?? 0) classified facts."
    }

    private func seedClassifiedSampleFacts() {
        guard !isSeedingSampleFacts else { return }
        isSeedingSampleFacts = true
        sampleStatus = nil
        sampleError = nil
        Task { @MainActor in
            do {
                let result = try selectedDomain.seedClassifiedFacts()
                sampleStats = result
                sampleStatus = "Seeded \(result.writtenThisRun) records. Total facts: \(result.total)."
                refreshSampleStats()
            } catch {
                sampleError = error.localizedDescription
            }
            isSeedingSampleFacts = false
        }
    }

    private func refreshSampleStats() {
        guard EdgeDataBootstrap.isReady else { return }
        sampleStats = try? selectedDomain.stats()
        let facts = (try? Edge.queryFacts(
            namespace: selectedDomain.namespace,
            status: .all,
            limit: 1_000
        )) ?? []
        classificationCorrectionCount = facts.filter { $0.classificationCorrectedAt != nil }.count
    }
}


private struct StageSegment: View {
    let stage: RPPStage
    let currentStage: RPPStage
    let hasError: Bool

    private enum SegmentState { case done, current, pending }

    private var state: SegmentState {
        if hasError && stage == currentStage { return .current }
        if stage.rawValue < currentStage.rawValue { return .done }
        if stage == currentStage { return .current }
        return .pending
    }

    private var iconName: String {
        switch state {
        case .done:    return "checkmark.circle.fill"
        case .current: return hasError ? "xmark.circle.fill" : "circle.dotted"
        case .pending: return "circle"
        }
    }

    private var color: Color {
        switch state {
        case .done:    return .green
        case .current: return hasError ? .red : .indigo
        case .pending: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: iconName)
                .font(.caption2)
                .foregroundStyle(color)
            Text(stage.shortLabel)
                .font(.system(size: 9, weight: state == .current ? .bold : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}


private struct DirectionCardView: View {
    let direction: RPPDirectionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(direction.llmName.isEmpty
                        ? RPPVocabulary.builtinDisplayNames[direction.directionKey]
                            ?? direction.directionKey
                        : direction.llmName)
                        .font(.headline)
                        .foregroundStyle(.indigo)
                    Text(direction.directionKey)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f", direction.projectionStats.std))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("std")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !direction.llmReason.isEmpty {
                Text(direction.llmReason)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Top-5 positive / negative") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Positive (highest projection):")
                        .font(.caption2.bold())
                    ForEach(0 ..< direction.topPositive.count, id: \.self) { i in
                        let pair = direction.topPositive[i]
                        Text(formatTopTxn(rank: i + 1, txn: pair.0, proj: pair.1))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.green)
                    }
                    Divider().padding(.vertical, 2)
                    Text("Negative (lowest projection):")
                        .font(.caption2.bold())
                    ForEach(0 ..< direction.topNegative.count, id: \.self) { i in
                        let pair = direction.topNegative[i]
                        Text(formatTopTxn(rank: i + 1, txn: pair.0, proj: pair.1))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }

    private func formatTopTxn(
        rank: Int, txn: RPPRawTransaction, proj: Float
    ) -> String {
        let loc = txn.location.isEmpty ? "(unknown)"
            : String(txn.location.prefix(20))
        return String(format: "  %d. [%+.2f] %@ %@ %@ %.0f",
            rank, proj, txn.weekday, txn.timeStr, loc, txn.amount)
    }
}


private struct ScatterChartView: View {
    let points: [RPPOutput.ScatterPoint]
    let xKey: String
    let yKey: String

    private var topKExtremals: [(label: String, point: RPPOutput.ScatterPoint)] {
        guard !points.isEmpty else { return [] }
        let topPosX = points.max(by: { $0.x < $1.x })
        let topNegX = points.min(by: { $0.x < $1.x })
        let topPosY = points.max(by: { $0.y < $1.y })
        let topNegY = points.min(by: { $0.y < $1.y })
        var result: [(String, RPPOutput.ScatterPoint)] = []
        if let p = topPosX { result.append(("\(xKey)+", p)) }
        if let p = topNegX { result.append(("\(xKey)-", p)) }
        if let p = topPosY { result.append(("\(yKey)+", p)) }
        if let p = topNegY { result.append(("\(yKey)-", p)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(points, id: \.txnIdx) { pt in
                PointMark(
                    x: .value(xKey, pt.x),
                    y: .value(yKey, pt.y)
                )
                .foregroundStyle(by: .value("Category", pt.category))
                .symbolSize(20)
                .opacity(0.65)
            }
            .chartXAxisLabel(xKey, position: .bottom, alignment: .center)
            .chartYAxisLabel(yKey, position: .leading, alignment: .center)
            .chartLegend(position: .bottom, alignment: .center, spacing: 4)
            .frame(height: 240)

            Text("Each point = 1 record, color = category, axes = RPP principal component projections")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !topKExtremals.isEmpty {
                DisclosureGroup("Top extremal records") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(topKExtremals.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.label)
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.indigo)
                                    .frame(width: 38, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.point.category)
                                        .font(.caption2)
                                    Text(String(format: "amount %.1f · proj (%.2f, %.2f)",
                                                 item.point.amount,
                                                 item.point.x,
                                                 item.point.y))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.bold())
            }
        }
    }
}


extension RPPStage {
    var displayName: String {
        switch self {
        case .loadingALibrary: return "Loading directions"
        case .templating: return "Preparing data"
        case .forwarding: return "Forward pass + capture"
        case .pcaAndBootstrap: return "Imprint Distillation"
        case .naming: return "Naming directions"
        case .profileNarrative: return "Generating profile"
        case .done: return "Done"
        @unknown default: return "Processing"
        }
    }

    var shortLabel: String {
        switch self {
        case .loadingALibrary:  return "Load"
        case .templating:       return "Data"
        case .forwarding:       return "Forward"
        case .pcaAndBootstrap:  return "Distill"
        case .naming:           return "Name"
        case .profileNarrative: return "Profile"
        case .done:             return ""
        @unknown default:       return "?"
        }
    }
}


private struct ActivityViewWrapper: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
