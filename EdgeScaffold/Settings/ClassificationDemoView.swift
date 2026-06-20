// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData


private enum RecordStatus: Equatable {
    case pending
    case queued
    case classifying
    case classified(category: String, confidence: Double)
    case failed(String)
}

private struct DemoRecord: Identifiable {
    let id = UUID()
    let sourceID: String?
    let description: String
    let rawPayload: [String: Any]
    var status: RecordStatus = .pending
    var factId: String?
}


struct ClassificationDemoView: View {
    @EnvironmentObject private var aiManager: AIManager

    @State private var records: [DemoRecord] = Self.makeDemoRecords()
    @State private var isRunning = false
    @State private var daemonStarted = false
    @State private var elapsedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var selectedFact: Fact?
    @State private var showCorrectionSheet = false

    private var classifiedCount: Int {
        records.filter { if case .classified = $0.status { return true }; return false }.count
    }

    var body: some View {
        List {
            Section {
                FeatureGuideHeader(
                    icon: "tag.fill",
                    title: "Auto Classification",
                    description: "LLM/VLM automatically classifies raw data into structured schema fields. User corrections feed back into the self-learning flywheel.",
                    steps: [
                        .init(number: 1, action: "App records synthetic raw events", api: "Edge.recordRaw(fact:)"),
                        .init(number: 2, action: "Daemon auto-classifies via LLM", api: "ClassificationDaemon.start(...)"),
                        .init(number: 3, action: "User reviews & corrects", api: "Edge.correctClassification(...)"),
                        .init(number: 4, action: "Corrections feed RPP self-learning", api: "EdgeHalo RPP"),
                    ],
                    developerNote: "Fork → replace the synthetic sample schema with your business schema, implement PromptBuilderProvider for domain-specific rules."
                )
            }

            Section {
                HStack {
                    if isRunning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(isRunning
                        ? "Classifying \(classifiedCount)/\(records.count)..."
                        : classifiedCount > 0
                            ? "Done! \(classifiedCount)/\(records.count) classified"
                            : "\(records.count) sample records ready")
                        .font(.subheadline.bold())
                    Spacer()
                    if isRunning || elapsedSeconds > 0 {
                        Text("\(elapsedSeconds)s")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach($records) { $record in
                    HStack(spacing: 10) {
                        statusIcon(record.status)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.description)
                                .font(.caption)
                                .lineLimit(2)

                            switch record.status {
                            case .pending:
                                Text("Ready")
                                    .font(.caption2).foregroundStyle(.secondary)
                            case .queued:
                                Text("Queued — waiting for daemon")
                                    .font(.caption2).foregroundStyle(.orange)
                            case .classifying:
                                Text("LLM classifying...")
                                    .font(.caption2).foregroundStyle(.indigo)
                            case .classified(let cat, let conf):
                                HStack(spacing: 4) {
                                    Text(cat)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                    Text(String(format: "%.0f%%", conf * 100))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            case .failed(let err):
                                Text(err)
                                    .font(.caption2).foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if case .classified = record.status, let fid = record.factId {
                            Button {
                                if let fact = (try? Edge.queryFacts(
                                    namespace: ScaffoldFinanceSample.namespace,
                                    status: .classifiedOnly
                                ))?.first(where: { $0.id == fid }) {
                                    selectedFact = fact
                                    showCorrectionSheet = true
                                }
                            } label: {
                                Image(systemName: "pencil.circle")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !isRunning {
                    Button {
                        startClassification()
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(classifiedCount > 0 ? "Re-run Classification" : "▶ Try Classification")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(!aiManager.isModelLoaded)
                    .padding(.top, 4)

                    if !aiManager.isModelLoaded {
                        Label("Model not loaded. Load in Settings → AI Engine first.",
                              systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Demo Records")
            } footer: {
                Text("Each record is synthetic demo data and is sent to the on-device LLM via ClassificationDaemon. ~5-10s per record.")
            }
        }
        .navigationTitle("Classification")
        .sheet(isPresented: $showCorrectionSheet) {
            if let fact = selectedFact {
                CorrectionSheetView(fact: fact) {
                    pollAndUpdateRecords()
                }
            }
        }
    }


    @ViewBuilder
    private func statusIcon(_ status: RecordStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .classifying:
            ProgressView()
                .scaleEffect(0.6)
        case .classified:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }


    private func startClassification() {
        isRunning = true
        elapsedSeconds = 0

        for i in records.indices {
            records[i].status = .pending
            records[i].factId = nil
        }

        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsedSeconds += 1
            }
        }

        Task {
            ScaffoldFinanceSample.registerSchema()

            for i in records.indices {
                do {
                    let customID = records[i].sourceID.map(ScaffoldFinanceSample.rawFactID(for:))
                    let factId = try Edge.recordRaw(
                        fact: RawFact(
                            namespace: ScaffoldFinanceSample.namespace,
                            rawPayload: records[i].rawPayload,
                            candidateSchemas: [ScaffoldFinanceSample.schemaName],
                            sensitivity: .meshOk
                        ),
                        customFactId: customID
                    )
                    records[i].factId = factId
                    records[i].status = .queued
                } catch {
                    records[i].status = .failed(error.localizedDescription)
                }
            }

            if !daemonStarted {
                Task.detached {
                    await ClassificationDaemon.shared.start(
                        namespace: ScaffoldFinanceSample.namespace,
                        candidateSchemas: [ScaffoldFinanceSample.schemaName],
                        llmClient: ScaffoldLLMClient.shared,
                        toolNames: ScaffoldTooling.sampleChatToolNames
                    )
                }
                daemonStarted = true
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                ClassificationDaemon.shared.wake()
            }

            if let firstQueued = records.firstIndex(where: { $0.status == .queued }) {
                records[firstQueued].status = .classifying
            }

            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                pollAndUpdateRecords()

                if classifiedCount >= records.count { break }
                let rawLeft = (try? Edge.countFacts(
                    namespace: ScaffoldFinanceSample.namespace,
                    status: .rawUnclassified)) ?? 0
                if rawLeft == 0 && classifiedCount >= records.filter({ $0.factId != nil }).count {
                    break
                }
            }

            timerTask?.cancel()
            isRunning = false
        }
    }

    private func pollAndUpdateRecords() {
        guard let facts = try? Edge.queryFacts(
            namespace: ScaffoldFinanceSample.namespace,
            status: .classifiedOnly
        ) else { return }

        let factMap = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })

        for i in records.indices {
            guard let fid = records[i].factId else { continue }
            if let fact = factMap[fid] {
                let cat = (fact.payload["category"] as? String) ?? "unknown"
                let conf = fact.classificationConfidence ?? 0
                records[i].status = .classified(category: cat, confidence: conf)
            } else if case .classified = records[i].status {
            } else if case .queued = records[i].status {
                let anyClassifying = records.contains { if case .classifying = $0.status { return true }; return false }
                if !anyClassifying {
                    records[i].status = .classifying
                }
            }
        }
    }

    private static func makeDemoRecords() -> [DemoRecord] {
        let financeRecords = ScaffoldFinanceSample.demoRecords(limit: 8)
        if !financeRecords.isEmpty {
            return financeRecords.map {
                DemoRecord(
                    sourceID: $0.id,
                    description: $0.summary,
                    rawPayload: $0.rawPayload
                )
            }
        }
        return ScaffoldDemoSchema.sampleRecords.map {
            DemoRecord(
                sourceID: nil,
                description: $0.description,
                rawPayload: $0.rawPayload
            )
        }
    }
}


private struct CorrectionSheetView: View {
    let fact: Fact
    let onDismiss: () -> Void

    @State private var correctedCategory: String = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    private let categories = ScaffoldFinanceSample.categories

    var body: some View {
        NavigationStack {
            List {
                Section("Classified Data") {
                    ForEach(fact.payload.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).font(.caption)
                            Spacer()
                            Text("\(String(describing: fact.payload[key] ?? "nil" as Any))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let conf = fact.classificationConfidence {
                    Section("Classification") {
                        HStack {
                            Text("Confidence")
                            Spacer()
                            Text(String(format: "%.1f%%", conf * 100))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Correct Category") {
                    Picker("Category", selection: $correctedCategory) {
                        Text("(no correction)").tag("")
                        ForEach(categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)

                    if !correctedCategory.isEmpty {
                        Button {
                            applyCorrection()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Save Correction")
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle("Review & Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let cat = fact.payload["category"] as? String {
                    correctedCategory = cat
                }
            }
        }
    }

    private func applyCorrection() {
        isSaving = true
        var correctedPayload = fact.payload
        correctedPayload["category"] = correctedCategory

        Task {
            do {
                try await Edge.correctClassification(
                    factId: fact.id,
                    newSchema: fact.schema,
                    newPayload: correctedPayload
                )
                onDismiss()
                dismiss()
            } catch {
                NSLog("[ClassificationDemo] correction failed: \(error)")
                isSaving = false
            }
        }
    }
}
