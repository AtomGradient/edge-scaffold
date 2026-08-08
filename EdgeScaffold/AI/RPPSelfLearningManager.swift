// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import SwiftUI
import EdgeHalo


enum RPPSelfLearningError: Error, LocalizedError {
    case bundleResourceMissing(String)
    case modelNotLoaded
    case unsupportedRuntime(String)
    case datasetEmpty
    case aLibraryUnavailable(String)
    case neuralImprintCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing(let n):
            return "缺少 RPP A-library 资源: \(n). 请通过 EdgeStudio 导出，或将授权的 RPP 资源放入 Resources/RPP。"
        case .modelNotLoaded:
            return "模型未加载, 先在 Settings → AI Engine 加载支持 hidden-state capture 的 Qwen3.5 模型"
        case .unsupportedRuntime(let runtime):
            return "当前 \(runtime.uppercased()) 运行时不支持 RPP capture；RPP 需要 Qwen3.5 LLM/VLM hidden-state capture"
        case .datasetEmpty:
            return "无可用数据 — 开发者: 替换 RPPDemoData 或接入 EdgeData classification"
        case .aLibraryUnavailable(let reason):
            return "RPP A-library 未配置: \(reason)。公共 scaffold 不内置 A-library。"
        case .neuralImprintCaptureFailed(let reason):
            return "Neural Imprint 生成失败: \(reason)"
        }
    }
}


@MainActor
final class RPPSelfLearningManager: ObservableObject {

    static let shared = RPPSelfLearningManager()
    private static let aLibraryVersion = "1.0.0"


    @Published private(set) var stage: RPPStage = .done
    @Published private(set) var stageDetail: String = ""
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var lastOutput: RPPOutput?
    @Published private(set) var lastError: String?
    @Published private(set) var datasetSize: Int = 0


    private var runTask: Task<Void, Never>?

    private init() {}

    var exportFileURL: URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = docs.appendingPathComponent("rpp_last_run.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var bDirectionsFileURL: URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let layer = lastOutput?.targetLayer ?? ScaffoldConfig.rppTargetLayer
        guard layer >= 0 else { return nil }
        let url = docs.appendingPathComponent("B_directions_layer_\(layer).safetensors")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }


    func start(aiManager: AIManager) {
        guard !isRunning else { return }
        runTask = Task { [weak self] in
            await self?.run(aiManager: aiManager)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    func reset() {
        guard !isRunning else { return }
        lastOutput = nil
        lastError = nil
        stage = .done
        stageDetail = ""
        progressFraction = 0
        elapsedSeconds = 0
        datasetSize = 0
    }

    var estimatedRemainingSeconds: Double {
        let total = RPPStage.totalBudgetSeconds
        return max(0, total * (1 - progressFraction))
    }


    private func run(aiManager: AIManager) async {
        isRunning = true
        lastError = nil
        lastOutput = nil
        elapsedSeconds = 0
        progressFraction = 0
        stage = .loadingALibrary
        stageDetail = "init"

        do {
            guard let manifestURL = Self.bundleRPPResourceURL(
                name: ScaffoldConfig.rppALibraryManifestResourceName,
                extension: "json"
            ) else {
                throw RPPSelfLearningError.aLibraryUnavailable(
                    "缺少 \(ScaffoldConfig.rppALibraryManifestResourceName).json"
                )
            }

            let domain = ScaffoldSampleDomainRegistry.selectedDomain
            let (selectedLibrary, usedFallback) = try Self.selectALibrary(
                manifestURL: manifestURL,
                preferredDirectionSetID: domain.rppDirectionSetID
            )
            guard let aURL = Self.bundleRPPResourceURL(fileName: selectedLibrary.artifact) else {
                throw RPPSelfLearningError.bundleResourceMissing(selectedLibrary.artifact)
            }
            if usedFallback {
                NSLog(
                    "[RPPSelfLearning] selected domain A-library missing, fallback to directions_a domain=%@",
                    domain.rppDirectionSetID
                )
            }

            try await runWith(
                aURL: aURL,
                manifestURL: manifestURL,
                selectedLibrary: selectedLibrary,
                usedFallback: usedFallback,
                aiManager: aiManager
            )

        } catch is CancellationError {
            self.lastError = "已取消"
        } catch {
            NSLog("[RPPSelfLearning] error: \(error)")
            self.lastError = error.localizedDescription
            self.stageDetail = "失败"
        }

        self.isRunning = false
    }

    private func runWith(
        aURL: URL,
        manifestURL: URL,
        selectedLibrary: RPPALibraryManifest.Library,
        usedFallback: Bool,
        aiManager: AIManager
    ) async throws {
        switch aiManager.modelCategory {
        case .llm:
            guard aiManager.llmEngine?.state == .ready else {
                throw RPPSelfLearningError.modelNotLoaded
            }
        case .vlm:
            guard aiManager.vlmEngine?.state == .ready else {
                throw RPPSelfLearningError.modelNotLoaded
            }
        default:
            throw RPPSelfLearningError.unsupportedRuntime(aiManager.modelCategory.rawValue)
        }

        self.stage = .templating
        self.stageDetail = "加载数据"
        self.progressFraction = 0.01
        let (sentences, rawTransactions) = RPPDemoData.loadData()
        guard !sentences.isEmpty else {
            throw RPPSelfLearningError.datasetEmpty
        }
        self.datasetSize = sentences.count
        self.stageDetail = "已加载 \(sentences.count) 条数据"
        let profileContext = Self.profileContext(for: ScaffoldSampleDomainRegistry.selectedDomain)

        let n = sentences.count
        let output = try await aiManager.runRPPProfileAnalysis(
            sentences: sentences,
            rawTransactions: rawTransactions,
            directionsAURL: aURL,
            aLibraryManifestURL: manifestURL,
            targetLayer: selectedLibrary.targetLayer,
            directionSetID: selectedLibrary.directionSetID,
            profileContext: profileContext,
            progress: { [weak self] (p: RPPProgress) in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.stage = p.stage
                    self.stageDetail = p.detail
                    self.elapsedSeconds = p.elapsedSeconds
                    self.progressFraction = self.computeProgressFraction(
                        stage: p.stage, detail: p.detail, n: n)
                }
            }
        )

        self.lastOutput = output
        self.elapsedSeconds = output.totalElapsedSeconds

        dumpResultJSON(
            output,
            selectedLibrary: selectedLibrary,
            manifestURL: manifestURL,
            usedFallback: usedFallback
        )
        dumpDirectionsB(output)

        self.stage = .profileNarrative
        self.stageDetail = "生成 Neural Imprint"
        self.progressFraction = 0.98
        let profileBody = Self.neuralImprintProfileBody(output: output)
        let neuralImprintStatus = try await {
            do {
                return try await aiManager.buildAndActivateCombinedNeuralImprint(
                    profileBody: profileBody
                )
            } catch {
                throw RPPSelfLearningError.neuralImprintCaptureFailed(
                    error.localizedDescription
                )
            }
        }()

        do {
            _ = try await MeshManager.shared.uploadLatestRPPArtifactsToMac()
        } catch {
            MeshManager.shared.lastRPPArtifactUploadError = error.localizedDescription
            NSLog("[RPPSelfLearning] RPP artifact mesh upload skipped/failed: %@", "\(error)")
        }
        MeshManager.shared.scheduleDeviceLearningSnapshotRefresh(reason: "rpp_self_learning_completed")

        self.stage = .done
        self.stageDetail = "完成 (\(output.directions.count) 段画像, " +
            "Neural Imprint \(neuralImprintStatus.prefixTokenCount) tokens, " +
            (usedFallback ? "fallback A-library, " : "") +
            String(format: "%.1f", output.totalElapsedSeconds) + "s)"
        self.progressFraction = 1.0
    }

    private static func selectALibrary(
        manifestURL: URL,
        preferredDirectionSetID: String
    ) throws -> (RPPALibraryManifest.Library, Bool) {
        let preferredRequirements = aLibraryRequirements(directionSetID: preferredDirectionSetID)
        if let selected = try RPPALibraryValidator.select(
            manifestURL: manifestURL,
            requirements: preferredRequirements
        ) {
            return (selected, false)
        }

        let fallbackDirectionSetID = "directions_a"
        guard preferredDirectionSetID != fallbackDirectionSetID,
              let fallback = try RPPALibraryValidator.select(
                  manifestURL: manifestURL,
                  requirements: aLibraryRequirements(directionSetID: fallbackDirectionSetID)
              ) else {
            throw RPPSelfLearningError.aLibraryUnavailable(
                "当前模型没有匹配的 \(preferredDirectionSetID) A-library"
            )
        }
        return (fallback, true)
    }

    private static func aLibraryRequirements(
        directionSetID: String
    ) -> RPPALibraryRuntimeRequirements {
        RPPALibraryRuntimeRequirements(
            modelFamily: ScaffoldConfig.rppModelFamily,
            hiddenSize: ScaffoldConfig.rppHiddenSize,
            layerCount: ScaffoldConfig.rppLayerCount,
            targetLayer: ScaffoldConfig.rppTargetLayer,
            directionSetID: directionSetID
        )
    }


    private func computeProgressFraction(
        stage: RPPStage, detail: String, n: Int
    ) -> Double {
        let baseFraction = stage.budgetCompletedFractionAtStart
        let stageBudget = stage.expectedSeconds
        let total = RPPStage.totalBudgetSeconds
        guard total > 0 else { return baseFraction }
        let stageWeight = stageBudget / total

        let withinStage: Double = {
            switch stage {
            case .forwarding:
                if let slashIdx = detail.firstIndex(of: "/") {
                    let lhs = detail[detail.startIndex ..< slashIdx]
                        .trimmingCharacters(in: .whitespaces)
                    if let done = Int(lhs), n > 0 {
                        return min(1.0, Double(done) / Double(n))
                    }
                }
                return 0
            case .naming:
                if detail.hasPrefix(ScaffoldConfig.rppBatchNamingProgressDetailPrefix) {
                    return 0.5
                }
                if let openIdx = detail.firstIndex(of: "("),
                   let slashIdx = detail.firstIndex(of: "/")
                {
                    let lhs = detail[detail.index(after: openIdx) ..< slashIdx]
                        .trimmingCharacters(in: .whitespaces)
                    if let done = Int(lhs) {
                        return min(1.0, Double(done) / 4.0)
                    }
                }
                return 0
            case .done:
                return 1.0
            default:
                return 0.5
            }
        }()

        return min(1.0, baseFraction + stageWeight * withinStage)
    }


    private func dumpResultJSON(
        _ output: RPPOutput,
        selectedLibrary: RPPALibraryManifest.Library,
        manifestURL: URL,
        usedFallback: Bool
    ) {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("rpp_last_run.json")
        do {
            let data = try Self.encode(
                output: output,
                selectedLibrary: selectedLibrary,
                manifestURL: manifestURL,
                usedFallback: usedFallback
            )
            try data.write(to: url)
            NSLog("[RPPSelfLearning] dumped result to %@", url.path)
        } catch {
            NSLog("[RPPSelfLearning] dump failed: %@", "\(error)")
        }
    }

    private static func encode(
        output: RPPOutput,
        selectedLibrary: RPPALibraryManifest.Library,
        manifestURL: URL,
        usedFallback: Bool
    ) throws -> Data {
        let provenance = Self.aLibraryProvenance(
            manifestURL: manifestURL,
            selectedLibrary: selectedLibrary
        )
        var dirs: [[String: Any]] = []
        for d in output.directions {
            dirs.append([
                "direction_idx": d.directionIdx,
                "direction_key": d.directionKey,
                "llm_name": d.llmName,
                "llm_reason": d.llmReason,
                "top_positive": d.topPositive.map { p -> [String: Any] in
                    ["category": p.transaction.category,
                     "location": p.transaction.location,
                     "amount": p.transaction.amount,
                     "projection": Double(p.projection)]
                },
                "top_negative": d.topNegative.map { p -> [String: Any] in
                    ["category": p.transaction.category,
                     "location": p.transaction.location,
                     "amount": p.transaction.amount,
                     "projection": Double(p.projection)]
                },
            ])
        }
        let dict: [String: Any] = [
            "rpp_run_id": output.rppRunID,
            "postprocessing_contract_version": output.postprocessingContractVersion,
            "n_transactions": output.nTransactions,
            "dataset_summary": datasetSummaryDict(output.datasetSummary),
            "target_layer": output.targetLayer,
            "a_library_id": selectedLibrary.libraryID,
            "a_library_kind": selectedLibrary.libraryKind,
            "direction_set_id": selectedLibrary.directionSetID,
            "a_yaml_sha256": provenance.yamlSHA256 ?? "",
            "a_source_type": provenance.sourceType ?? "",
            "a_source_schema_version": provenance.sourceSchemaVersion ?? "",
            "a_artifact": selectedLibrary.artifact,
            "a_health_report": selectedLibrary.healthReport,
            "a_health_verdict": selectedLibrary.healthVerdict,
            "a_version": Self.aLibraryVersion,
            "a_hash": output.aHashHex,
            "used_fallback": usedFallback,
            "usedFallback": usedFallback,
            "k_selected": output.kSelected,
            "total_elapsed_seconds": output.totalElapsedSeconds,
            "directions": dirs,
            "profile_narrative": output.profileNarrative ?? "",
        ]
        return try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys])
    }

    private struct ALibraryProvenance {
        let yamlSHA256: String?
        let sourceType: String?
        let sourceSchemaVersion: String?
    }

    private static func aLibraryProvenance(
        manifestURL: URL,
        selectedLibrary: RPPALibraryManifest.Library
    ) -> ALibraryProvenance {
        let reportURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(selectedLibrary.healthReport)
        let report = Self.readJSONObject(at: reportURL)
        let library = Self.manifestLibraryObject(
            manifestURL: manifestURL,
            selectedLibrary: selectedLibrary
        )
        return ALibraryProvenance(
            yamlSHA256: Self.stringValue(report?["yaml_sha256"])
                ?? Self.stringValue(library?["yaml_sha256"]),
            sourceType: Self.stringValue(report?["source_type"])
                ?? Self.stringValue(library?["source_type"]),
            sourceSchemaVersion: Self.stringValue(report?["source_schema_version"])
                ?? Self.stringValue(library?["source_schema_version"])
        )
    }

    private static func manifestLibraryObject(
        manifestURL: URL,
        selectedLibrary: RPPALibraryManifest.Library
    ) -> [String: Any]? {
        guard let manifest = Self.readJSONObject(at: manifestURL),
              let libraries = manifest["libraries"] as? [[String: Any]] else {
            return nil
        }
        return libraries.first {
            Self.stringValue($0["library_id"]) == selectedLibrary.libraryID
        } ?? libraries.first {
            Self.stringValue($0["direction_set_id"]) == selectedLibrary.directionSetID
                && Self.stringValue($0["artifact"]) == selectedLibrary.artifact
        }
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dumpDirectionsB(_ output: RPPOutput) {
        guard output.directionsB.rows > 0,
              output.directionsB.rows == output.directionsBKeys.count else {
            return
        }
        guard let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let url = docs.appendingPathComponent(
            "B_directions_layer_\(output.targetLayer).safetensors"
        )
        do {
            try output.directionsB.writeNamedRowSafetensors(
                to: url,
                rowNames: output.directionsBKeys
            )
            NSLog("[RPPSelfLearning] dumped B directions to %@", url.path)
        } catch {
            NSLog("[RPPSelfLearning] B directions dump failed: %@", "\(error)")
        }
    }

    private static func neuralImprintProfileBody(output: RPPOutput) -> String {
        let summary = output.datasetSummary
        var sections: [String] = []
        sections.append(
            """
            RPP run \(output.rppRunID)
            数据范围：\(output.nTransactions) 条已分类 scaffold sample facts，target_layer=\(output.targetLayer)，k_selected=\(output.kSelected)
            金额摘要：total=\(formatAmount(summary.totalAmount))，average=\(formatAmount(summary.averageAmount))，median=\(formatAmount(summary.medianAmount))，max=\(formatAmount(summary.maxAmount))
            """
        )

        let topCategoriesByCount = bucketLine(
            title: "按次数最高的类别",
            buckets: summary.topCategoriesByCount
        )
        if !topCategoriesByCount.isEmpty {
            sections.append(topCategoriesByCount)
        }
        let topCategoriesByAmount = bucketLine(
            title: "按金额最高的类别",
            buckets: summary.topCategoriesByAmount
        )
        if !topCategoriesByAmount.isEmpty {
            sections.append(topCategoriesByAmount)
        }
        let topWeekdaysByCount = bucketLine(
            title: "按次数最高的星期",
            buckets: summary.topWeekdaysByCount
        )
        if !topWeekdaysByCount.isEmpty {
            sections.append(topWeekdaysByCount)
        }

        if let narrative = output.profileNarrative?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !narrative.isEmpty {
            sections.append("综合画像：\n\(narrative)")
        }

        let directions = output.directions.compactMap { direction -> String? in
            let name = direction.llmName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = direction.directionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? key : name
            let reason = direction.llmReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !reason.isEmpty else { return nil }
            if reason.isEmpty {
                return "- \(title)"
            }
            if title.isEmpty {
                return "- \(reason)"
            }
            return "- \(title)：\(reason)"
        }
        if !directions.isEmpty {
            sections.append("RPP 画像方向：\n" + directions.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    private static func profileContext(for domain: ScaffoldSampleDomainDescriptor) -> RPPProfileContext {
        guard domain.id != .finance else { return .finance }
        return RPPProfileContext(
            domainID: domain.id.rawValue,
            domainDisplayName: domain.displayName,
            recordNoun: "记录",
            valueNoun: "记录值",
            analystRole: "熟悉该领域的个人分析助手"
        )
    }

    private static func bucketLine(
        title: String,
        buckets: [RPPDatasetSummary.Bucket]
    ) -> String {
        let entries = buckets.prefix(8).map { bucket in
            "\(bucket.key)(count=\(bucket.count), total=\(formatAmount(bucket.totalAmount)), avg=\(formatAmount(bucket.averageAmount)))"
        }
        guard !entries.isEmpty else { return "" }
        return "\(title)：\(entries.joined(separator: "；"))"
    }

    private static func formatAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func datasetSummaryDict(_ summary: RPPDatasetSummary) -> [String: Any] {
        func bucket(_ value: RPPDatasetSummary.Bucket) -> [String: Any] {
            [
                "key": value.key,
                "count": value.count,
                "total_amount": value.totalAmount,
                "average_amount": value.averageAmount,
            ]
        }
        return [
            "total_count": summary.totalCount,
            "total_amount": summary.totalAmount,
            "average_amount": summary.averageAmount,
            "median_amount": summary.medianAmount,
            "max_amount": summary.maxAmount,
            "top_categories_by_count": summary.topCategoriesByCount.map(bucket),
            "top_categories_by_amount": summary.topCategoriesByAmount.map(bucket),
            "top_weekdays_by_count": summary.topWeekdaysByCount.map(bucket),
        ]
    }

    private static func bundleRPPResourceURL(name: String, extension ext: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "RPP"
        ) ?? Bundle.main.url(
            forResource: name,
            withExtension: ext
        )
    }

    private static func bundleRPPResourceURL(fileName: String) -> URL? {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, !ext.isEmpty else { return nil }
        return bundleRPPResourceURL(name: name, extension: ext)
    }
}
