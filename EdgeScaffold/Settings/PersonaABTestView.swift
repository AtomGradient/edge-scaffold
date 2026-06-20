// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeUI

@MainActor
struct PersonaABTestView: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared

    @State private var runState: RunState = .idle
    @State private var results: [QuestionResult] = []
    @State private var currentIndex: Int = 0
    @State private var errorText: String?
    @State private var shareURL: URL?

    enum RunState: Equatable {
        case idle
        case running
        case done
    }

    struct QuestionResult: Identifiable, Codable {
        let question: String
        let isPersonaProbe: Bool
        var answer: String = ""
        var elapsedS: Double = 0
        var id: String { question }
    }

    static let questions: [(String, Bool)] = [
        ("我的消费习惯是什么？", true),
        ("我上个月花了多少钱？", true),
        ("我常去哪些商家？", true),
        ("我有哪些长期偏好？", true),
        ("中国的首都是哪里？", false),
        ("1+1 等于几？", false),
        ("李白有哪些著名诗词？", false),
    ]

    var body: some View {
        Form {
            Section {
                statusRow
                Button(runState == .running ? "运行中..." : "开始 Neural Imprint Smoke") {
                    Task { await runSmoke() }
                }
                .disabled(runState == .running || !aiManager.isModelLoaded)
                if let err = errorText {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            } header: {
                Text("Neural Imprint Smoke")
            }

            if !results.isEmpty {
                Section("结果 · \(results.count) 题") {
                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(r.question).font(.headline)
                                Spacer()
                                Text(r.isPersonaProbe ? "画像" : "对照")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background((r.isPersonaProbe ? Color.blue : Color.gray).opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Text(r.answer.isEmpty ? "-" : r.answer)
                                .font(.callout)
                                .textSelection(.enabled)
                            Text(String(format: "%.1fs", r.elapsedS))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if runState == .done {
                    Section {
                        Button("导出 JSON 结果") {
                            shareURL = exportResults()
                        }
                    }
                }
            }
        }
        .navigationTitle("Persona Smoke")
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { shareURL = $0?.url }
        )) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private var statusRow: some View {
        HStack {
            Image(systemName: aiManager.hasNeuralImprintCache ? "brain.head.profile.fill" : "brain.head.profile")
                .foregroundStyle(aiManager.hasNeuralImprintCache ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(aiManager.loadedModelName ?? "no model loaded")
                    .font(.callout)
                if let status = aiManager.neuralImprintCacheStatus {
                    Text(diagnostics.isDetailedMetricsEnabled
                         ? "Neural Imprint active · \(status.prefixTokenCount) tokens"
                         : "Neural Imprint · active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .edgeDiagnosticTapGesture()
                } else {
                    Text("Neural Imprint not active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if runState == .running {
                ProgressView()
            }
        }
    }

    private static let autoResultPath: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("neural_imprint_smoke_latest.json")
    }()

    private func runSmoke() async {
        errorText = nil
        guard aiManager.isModelLoaded, aiManager.llmEngine != nil else {
            errorText = "LLM 未加载"
            return
        }
        runState = .running
        results = Self.questions.map { QuestionResult(question: $0.0, isPersonaProbe: $0.1) }
        writeAutoResult(phase: "started")

        let params = AIManager.defaultParameters()
        let system = ScaffoldConfig.defaultSystemPrompt
        for i in 0..<results.count {
            currentIndex = i
            var answer = ""
            let startT = Date()
            do {
                for try await chunk in aiManager.generate(
                    messages: [.system(system), .user(results[i].question)],
                    parameters: params
                ) {
                    answer += chunk
                    if answer.count > 1200 { break }
                }
            } catch {
                answer = "<error: \(error.localizedDescription)>"
            }
            results[i].answer = answer
            results[i].elapsedS = Date().timeIntervalSince(startT)
            writeAutoResult(phase: "\(i + 1)_of_\(results.count)")
        }

        runState = .done
        writeAutoResult(phase: "done")
    }

    private func writeAutoResult(phase: String) {
        let payload: [String: Any] = [
            "phase": phase,
            "model": aiManager.loadedModelName ?? "unknown",
            "neural_imprint_active": aiManager.hasNeuralImprintCache,
            "neural_imprint_prefix_tokens": aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "results": results.map { [
                "question": $0.question,
                "is_persona_probe": $0.isPersonaProbe,
                "answer": $0.answer,
                "elapsed_s": $0.elapsedS,
            ]},
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: Self.autoResultPath, options: [.atomic])
    }

    private func exportResults() -> URL? {
        let payload: [String: Any] = [
            "device": aiManager.loadedModelName ?? "unknown",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "neural_imprint_active": aiManager.hasNeuralImprintCache,
            "results": results.map { [
                "question": $0.question,
                "is_persona_probe": $0.isPersonaProbe,
                "answer": $0.answer,
            ]},
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return nil
        }
        let ts = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neural_imprint_smoke_\(ts).json")
        try? data.write(to: url)
        return url
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

#if canImport(UIKit)
import UIKit
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheet: View {
    let activityItems: [Any]
    var body: some View { Text("Share") }
}
#endif
