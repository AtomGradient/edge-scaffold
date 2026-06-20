// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Darwin
import Foundation
import EdgeData
import EdgeInference

enum ScaffoldDomainSmokeRunner {
    static let launchArgument = "--scaffold-domain-smoke"
    static let resultFileName = "scaffold_domain_smoke_result.json"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func runAndExit() {
        Task {
            let report = await run()
            do {
                try write(report)
            } catch {
                NSLog("[ScaffoldDomainSmokeRunner] failed to write report: \(error.localizedDescription)")
            }
            NSLog("[ScaffoldDomainSmokeRunner] completed passed=\(report.passed) domains=\(report.results.count)")
            Darwin.exit(report.passed ? 0 : 1)
        }
    }

    private static func run() async -> DomainSmokeReport {
        let startedAt = Date()
        var results: [DomainSmokeResult] = []

        for domain in ScaffoldSampleDomainRegistry.all {
            results.append(await smoke(domain: domain))
        }

        let finishedAt = Date()
        return DomainSmokeReport(
            schemaVersion: "edge_scaffold.domain_smoke.v1",
            startedAt: isoString(from: startedAt),
            finishedAt: isoString(from: finishedAt),
            durationMs: Int(finishedAt.timeIntervalSince(startedAt) * 1_000),
            passed: results.allSatisfy(\.passed),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            runtimeMetadata: runtimeMetadata(),
            results: results
        )
    }

    private static func smoke(domain: ScaffoldSampleDomainDescriptor) async -> DomainSmokeResult {
        var errors: [String] = []
        let expectedRecords: Int
        let seedStats: DomainSeedStats
        let registeredTools: [String]
        let staleToolsPresent: [String]
        let staleToolReject: StaleToolRejectResult
        let aggregate: ToolSmokeResult
        let filter: ToolSmokeResult

        do {
            expectedRecords = try domain.loadRecordCount()
        } catch {
            return DomainSmokeResult(
                domain: domain.id.rawValue,
                displayName: domain.displayName,
                namespace: domain.namespace,
                expectedRecords: 0,
                seedStats: nil,
                registeredTools: [],
                staleToolsPresent: [],
                staleToolReject: nil,
                aggregate: nil,
                filter: nil,
                passed: false,
                errors: ["loadRecordCount failed: \(error.localizedDescription)"]
            )
        }

        do {
            let stats = try await seedAndLoadStats(domain: domain)
            seedStats = DomainSeedStats(stats)

            if stats.sampleRecords != expectedRecords {
                errors.append("sampleRecords \(stats.sampleRecords) != expected \(expectedRecords)")
            }
            if stats.classified != expectedRecords {
                errors.append("classified \(stats.classified) != expected \(expectedRecords)")
            }
            if stats.rawUnclassified != expectedRecords {
                errors.append("rawUnclassified \(stats.rawUnclassified) != expected \(expectedRecords)")
            }
        } catch {
            return DomainSmokeResult(
                domain: domain.id.rawValue,
                displayName: domain.displayName,
                namespace: domain.namespace,
                expectedRecords: expectedRecords,
                seedStats: nil,
                registeredTools: [],
                staleToolsPresent: [],
                staleToolReject: nil,
                aggregate: nil,
                filter: nil,
                passed: false,
                errors: ["seed/stats failed: \(error.localizedDescription)"]
            )
        }

        registeredTools = ToolRegistry.shared.allSchemas().map(\.name).sorted()
        let expectedToolNames = Set(domain.toolProvider.toolNames)
        let registeredToolSet = Set(registeredTools)
        let missingTools = expectedToolNames.subtracting(registeredToolSet).sorted()
        let extraTools = registeredToolSet.subtracting(expectedToolNames).sorted()
        let nonCurrentTools = Set(ScaffoldSampleDomainRegistry.all
            .filter { $0.id != domain.id }
            .flatMap { $0.toolProvider.toolNames })
        staleToolsPresent = registeredToolSet.intersection(nonCurrentTools).sorted()

        if !missingTools.isEmpty {
            errors.append("missing tools: \(missingTools.joined(separator: ","))")
        }
        if !extraTools.isEmpty {
            errors.append("extra tools: \(extraTools.joined(separator: ","))")
        }
        if !staleToolsPresent.isEmpty {
            errors.append("stale tools still registered: \(staleToolsPresent.joined(separator: ","))")
        }

        staleToolReject = await verifyStaleToolReject(for: domain)
        if !(staleToolReject.passed) {
            errors.append("stale tool reject failed: \(staleToolReject.error ?? "unknown")")
        }

        aggregate = await runTool(plan: aggregatePlan(for: domain), mode: "aggregate")
        if !(aggregate.passed) {
            errors.append("aggregate failed: \(aggregate.error ?? aggregate.failureReason ?? "unknown")")
        }

        filter = await runTool(plan: filterPlan(for: domain), mode: "filter")
        if !(filter.passed) {
            errors.append("filter failed: \(filter.error ?? filter.failureReason ?? "unknown")")
        }

        return DomainSmokeResult(
            domain: domain.id.rawValue,
            displayName: domain.displayName,
            namespace: domain.namespace,
            expectedRecords: expectedRecords,
            seedStats: seedStats,
            registeredTools: registeredTools,
            staleToolsPresent: staleToolsPresent,
            staleToolReject: staleToolReject,
            aggregate: aggregate,
            filter: filter,
            passed: errors.isEmpty,
            errors: errors
        )
    }

    private static func seedAndLoadStats(
        domain: ScaffoldSampleDomainDescriptor,
        attempts: Int = 4
    ) async throws -> ScaffoldSampleDomainSeedResult {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                _ = try ScaffoldSampleDomainRegistry.switchToDomain(rawValue: domain.id.rawValue)
                _ = try domain.seedClassifiedFacts()
                return try domain.stats()
            } catch {
                lastError = error
                guard attempt < attempts, isTransientDatabaseLock(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
            }
        }
        throw lastError ?? SmokeError.seedStatsUnavailable
    }

    private static func isTransientDatabaseLock(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("database is locked") || text.contains("sqlite error 5")
    }

    private static func verifyStaleToolReject(for domain: ScaffoldSampleDomainDescriptor) async -> StaleToolRejectResult {
        guard let staleName = ScaffoldSampleDomainRegistry.all
            .first(where: { $0.id != domain.id })?
            .toolProvider
            .toolNames
            .first
        else {
            return StaleToolRejectResult(toolName: nil, passed: true, error: nil)
        }

        do {
            _ = try await ToolRegistry.shared.execute(ToolCallPlan(toolName: staleName))
            return StaleToolRejectResult(
                toolName: staleName,
                passed: false,
                error: "stale tool unexpectedly executed"
            )
        } catch ToolRegistryError.toolNotFound {
            return StaleToolRejectResult(toolName: staleName, passed: true, error: nil)
        } catch {
            return StaleToolRejectResult(
                toolName: staleName,
                passed: false,
                error: error.localizedDescription
            )
        }
    }

    private static func runTool(plan: ToolCallPlan, mode: String) async -> ToolSmokeResult {
        do {
            let output = try await ToolRegistry.shared.execute(plan)
            let parsed = try parseToolOutput(output)
            let passed = parsed.matchedCount > 0
                && parsed.totalClassified > 0
                && parsed.hasUsefulPayload
                && (mode != "filter" || parsed.isSubsetLike)
            return ToolSmokeResult(
                mode: mode,
                toolName: plan.toolName,
                arguments: plan.arguments.mapValues(renderAuditValue),
                matchedCount: parsed.matchedCount,
                totalClassified: parsed.totalClassified,
                numericTotal: parsed.numericTotal,
                groupCount: parsed.groupCount,
                itemCount: parsed.itemCount,
                resultPrefix: String(output.prefix(240)),
                passed: passed,
                failureReason: passed ? nil : parsed.failureReason(mode: mode),
                error: nil
            )
        } catch {
            return ToolSmokeResult(
                mode: mode,
                toolName: plan.toolName,
                arguments: plan.arguments.mapValues(renderAuditValue),
                matchedCount: 0,
                totalClassified: 0,
                numericTotal: 0,
                groupCount: 0,
                itemCount: 0,
                resultPrefix: "",
                passed: false,
                failureReason: nil,
                error: error.localizedDescription
            )
        }
    }

    private static func aggregatePlan(for domain: ScaffoldSampleDomainDescriptor) -> ToolCallPlan {
        switch domain.id {
        case .finance:
            return ToolCallPlan(toolName: ScaffoldTooling.expenseSummaryToolName, arguments: [
                "record_type": .string("expense"),
                "group_by": .string("category"),
            ])
        case .health:
            return ToolCallPlan(toolName: ScaffoldHealthTooling.workoutToolName)
        case .reading:
            return ToolCallPlan(toolName: ScaffoldReadingTooling.readingHistoryToolName)
        case .journal:
            return ToolCallPlan(toolName: ScaffoldJournalTooling.tasksToolName)
        case .travel:
            return ToolCallPlan(toolName: ScaffoldTravelTooling.spendingToolName)
        case .cooking:
            return ToolCallPlan(toolName: ScaffoldCookingTooling.spendingToolName)
        case .music:
            return ToolCallPlan(toolName: ScaffoldMusicTooling.listeningToolName)
        case .work:
            return ToolCallPlan(toolName: ScaffoldWorkTooling.summaryToolName)
        }
    }

    private static func filterPlan(for domain: ScaffoldSampleDomainDescriptor) -> ToolCallPlan {
        switch domain.id {
        case .finance:
            return ToolCallPlan(toolName: ScaffoldTooling.expenseSearchToolName, arguments: [
                "record_type": .string("expense"),
                "category": .string("dining"),
                "limit": .int(5),
            ])
        case .health:
            return ToolCallPlan(toolName: ScaffoldHealthTooling.workoutToolName, arguments: [
                "activity": .string("跑步"),
                "limit": .int(5),
            ])
        case .reading:
            return ToolCallPlan(toolName: ScaffoldReadingTooling.readingHistoryToolName, arguments: [
                "category": .string("tech"),
                "limit": .int(5),
            ])
        case .journal:
            return ToolCallPlan(toolName: ScaffoldJournalTooling.tasksToolName, arguments: [
                "status": .string("pending"),
                "limit": .int(5),
            ])
        case .travel:
            return ToolCallPlan(toolName: ScaffoldTravelTooling.recordsToolName, arguments: [
                "record_type": .string("dining_out"),
                "limit": .int(5),
            ])
        case .cooking:
            return ToolCallPlan(toolName: ScaffoldCookingTooling.recordsToolName, arguments: [
                "cuisine": .string("chinese_home"),
                "limit": .int(5),
            ])
        case .music:
            return ToolCallPlan(toolName: ScaffoldMusicTooling.recordsToolName, arguments: [
                "genre": .string("pop"),
                "limit": .int(5),
            ])
        case .work:
            return ToolCallPlan(toolName: ScaffoldWorkTooling.recordsToolName, arguments: [
                "project": .string("端侧 AI SDK"),
                "limit": .int(5),
            ])
        }
    }

    private static func parseToolOutput(_ output: String) throws -> ParsedToolOutput {
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        guard let dict = object as? [String: Any] else {
            throw SmokeError.invalidToolJSON
        }
        let matchedCount = intValue(dict["matched_count"] ?? dict["matchedCount"]) ?? 0
        let totalClassified = intValue(dict["total_classified"] ?? dict["totalClassified"]) ?? 0
        let groups = dict["groups"] as? [[String: Any]] ?? []
        let items = dict["items"] as? [[String: Any]] ?? []
        let numericTotal = [
            "total_amount",
            "total_cost",
            "total_duration_minutes",
            "total_calories",
            "total_pages_read",
        ].compactMap { doubleValue(dict[$0]) }.first(where: { $0 > 0 }) ?? 0
        return ParsedToolOutput(
            matchedCount: matchedCount,
            totalClassified: totalClassified,
            numericTotal: numericTotal,
            groupCount: groups.count,
            itemCount: items.count
        )
    }

    private static func write(_ report: DomainSmokeReport) throws {
        let url = documentsURL().appendingPathComponent(resultFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func runtimeMetadata() -> DomainSmokeRuntimeMetadata {
        let hostMetadata = hostBuildMetadata()
        return DomainSmokeRuntimeMetadata(
            edgeKitVersion: EdgeKitRuntime.version,
            edgeEngineVersion: EdgeKitRuntime.nativeRuntimeVersion,
            appBuild: DomainSmokeAppBuildMetadata(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                gitSHAs: hostMetadata?.gitSHAs ?? [:],
                dependencyVersions: hostMetadata?.dependencyVersions ?? [:],
                demoReadyTag: hostMetadata?.demoReadyTag,
                demoReadyTagExact: hostMetadata?.demoReadyTagExact ?? false
            )
        )
    }

    private static func hostBuildMetadata() -> DomainSmokeBuildMetadata? {
        let url = documentsURL().appendingPathComponent("device_test_build_metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DomainSmokeBuildMetadata.self, from: data)
    }

    private static func renderAuditValue(_ value: AuditValue) -> String {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return "null"
        case .array(let values):
            return "[" + values.map(renderAuditValue).joined(separator: ",") + "]"
        case .object(let values):
            let fields = values.keys.sorted().map { key in
                "\(key):\(renderAuditValue(values[key] ?? .null))"
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct DomainSmokeReport: Encodable {
    let schemaVersion: String
    let startedAt: String
    let finishedAt: String
    let durationMs: Int
    let passed: Bool
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let runtimeMetadata: DomainSmokeRuntimeMetadata
    let results: [DomainSmokeResult]
}

private struct DomainSmokeBuildMetadata: Decodable {
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}

private struct DomainSmokeRuntimeMetadata: Encodable {
    let edgeKitVersion: String
    let edgeEngineVersion: String
    let appBuild: DomainSmokeAppBuildMetadata
}

private struct DomainSmokeAppBuildMetadata: Encodable {
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}

private struct DomainSmokeResult: Encodable {
    let domain: String
    let displayName: String
    let namespace: String
    let expectedRecords: Int
    let seedStats: DomainSeedStats?
    let registeredTools: [String]
    let staleToolsPresent: [String]
    let staleToolReject: StaleToolRejectResult?
    let aggregate: ToolSmokeResult?
    let filter: ToolSmokeResult?
    let passed: Bool
    let errors: [String]
}

private struct DomainSeedStats: Encodable {
    let sampleRecords: Int
    let writtenThisRun: Int
    let rawUnclassified: Int
    let classified: Int
    let total: Int

    init(_ result: ScaffoldSampleDomainSeedResult) {
        sampleRecords = result.sampleRecords
        writtenThisRun = result.writtenThisRun
        rawUnclassified = result.rawUnclassified
        classified = result.classified
        total = result.total
    }
}

private struct StaleToolRejectResult: Encodable {
    let toolName: String?
    let passed: Bool
    let error: String?
}

private struct ToolSmokeResult: Encodable {
    let mode: String
    let toolName: String
    let arguments: [String: String]
    let matchedCount: Int
    let totalClassified: Int
    let numericTotal: Double
    let groupCount: Int
    let itemCount: Int
    let resultPrefix: String
    let passed: Bool
    let failureReason: String?
    let error: String?
}

private struct ParsedToolOutput {
    let matchedCount: Int
    let totalClassified: Int
    let numericTotal: Double
    let groupCount: Int
    let itemCount: Int

    var hasUsefulPayload: Bool {
        numericTotal > 0 || groupCount > 0 || itemCount > 0
    }

    var isSubsetLike: Bool {
        matchedCount < totalClassified || (itemCount > 0 && itemCount <= 5)
    }

    func failureReason(mode: String) -> String {
        if matchedCount <= 0 { return "\(mode) matched_count is zero" }
        if totalClassified <= 0 { return "\(mode) total_classified is zero" }
        if !hasUsefulPayload { return "\(mode) has no useful payload" }
        if mode == "filter", !isSubsetLike { return "\(mode) did not return subset-like result" }
        return "\(mode) failed unknown validation"
    }
}

private enum SmokeError: Error {
    case invalidToolJSON
    case seedStatsUnavailable
}
