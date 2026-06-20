// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference
import EdgeSession
import EdgeData
import GRDB

enum ScaffoldSampleDomainID: String, CaseIterable, Identifiable {
    case finance
    case health
    case reading
    case journal
    case travel
    case cooking
    case music
    case work

    var id: String { rawValue }
}

struct ScaffoldSampleDomainSeedResult: Equatable {
    let sampleRecords: Int
    let writtenThisRun: Int
    let rawUnclassified: Int
    let classified: Int
    let total: Int
}

protocol ScaffoldSampleDomainToolProviding {
    var toolNames: [String] { get }
    func registerTools(in registry: ToolRegistry)
}

struct ScaffoldSampleDomainDescriptor: Identifiable {
    let id: ScaffoldSampleDomainID
    let displayName: String
    let namespace: String
    let schemaName: String
    let resourceName: String
    let rppDirectionSetID: String
    let summary: String
    let toolProvider: any ScaffoldSampleDomainToolProviding

    private let registerSchemaAction: () -> Void
    private let loadRecordCountAction: () throws -> Int
    private let seedRawFactsAction: (Int?) throws -> ScaffoldSampleDomainSeedResult
    private let seedClassifiedFactsAction: (Int?) throws -> ScaffoldSampleDomainSeedResult
    private let statsAction: () throws -> ScaffoldSampleDomainSeedResult

    init(
        id: ScaffoldSampleDomainID,
        displayName: String,
        namespace: String,
        schemaName: String,
        resourceName: String,
        rppDirectionSetID: String,
        summary: String,
        toolProvider: any ScaffoldSampleDomainToolProviding,
        registerSchema: @escaping () -> Void,
        loadRecordCount: @escaping () throws -> Int,
        seedRawFacts: @escaping (Int?) throws -> ScaffoldSampleDomainSeedResult,
        seedClassifiedFacts: @escaping (Int?) throws -> ScaffoldSampleDomainSeedResult,
        stats: @escaping () throws -> ScaffoldSampleDomainSeedResult
    ) {
        self.id = id
        self.displayName = displayName
        self.namespace = namespace
        self.schemaName = schemaName
        self.resourceName = resourceName
        self.rppDirectionSetID = rppDirectionSetID
        self.summary = summary
        self.toolProvider = toolProvider
        self.registerSchemaAction = registerSchema
        self.loadRecordCountAction = loadRecordCount
        self.seedRawFactsAction = seedRawFacts
        self.seedClassifiedFactsAction = seedClassifiedFacts
        self.statsAction = stats
    }

    func registerSchema() {
        registerSchemaAction()
    }

    func loadRecordCount() throws -> Int {
        try loadRecordCountAction()
    }

    func seedRawFacts(limit: Int? = nil) throws -> ScaffoldSampleDomainSeedResult {
        try seedRawFactsAction(limit)
    }

    func seedClassifiedFacts(limit: Int? = nil) throws -> ScaffoldSampleDomainSeedResult {
        try seedClassifiedFactsAction(limit)
    }

    func stats() throws -> ScaffoldSampleDomainSeedResult {
        try statsAction()
    }

    var toolPromptExamples: [String] {
        switch id {
        case .finance:
            return ["我这个月餐饮花了多少钱？", "按类别总结一下我的消费"]
        case .health:
            return ["我最近跑步训练怎么样？", "总结一下我的睡眠和恢复情况"]
        case .reading:
            return ["我最近读了哪些技术内容？", "按主题总结一下我的阅读习惯"]
        case .journal:
            return ["我最近有哪些高优先级任务？", "总结一下我的情绪和待办模式"]
        case .travel:
            return ["我最近旅行花费主要在哪里？", "总结一下我的出行偏好"]
        case .cooking:
            return ["我最近常做什么菜？", "总结一下我的烹饪和采购习惯"]
        case .music:
            return ["我最近常听什么类型的内容？", "总结一下我的音乐和媒体偏好"]
        case .work:
            return ["我最近在哪些项目上投入最多？", "总结一下我的会议和工作模式"]
        }
    }

    var profilePromptExamples: [String] {
        switch id {
        case .finance:
            return ["我的消费习惯是什么？", "给我推荐一个周末活动"]
        case .health:
            return ["我的健康习惯是什么？", "我应该注意哪些恢复模式？"]
        case .reading:
            return ["我的学习偏好是什么？", "下一本书适合读什么方向？"]
        case .journal:
            return ["我的近期状态是什么？", "我应该优先处理什么？"]
        case .travel:
            return ["我的旅行偏好是什么？", "下次行程应该怎么安排？"]
        case .cooking:
            return ["我的饮食偏好是什么？", "这周适合做什么菜？"]
        case .music:
            return ["我的媒体偏好是什么？", "推荐一些符合我口味的内容"]
        case .work:
            return ["我的工作模式是什么？", "我最近的主要瓶颈是什么？"]
        }
    }
}

enum ScaffoldSampleDomainRegistry {
    static let selectedDomainDefaultsKey = "scaffold_selected_domain"

    static var all: [ScaffoldSampleDomainDescriptor] {
        [
            .finance,
            .health,
            .reading,
            .journal,
            .travel,
            .cooking,
            .music,
            .work,
        ]
    }

    static var defaultDomain: ScaffoldSampleDomainDescriptor {
        if let id = ScaffoldSampleDomainID(rawValue: ScaffoldConfig.defaultSampleDomainID),
           let descriptor = descriptor(for: id) {
            return descriptor
        }
        return .finance
    }

    static var selectedDomain: ScaffoldSampleDomainDescriptor {
        descriptor(forRawValue: UserDefaults.standard.string(forKey: selectedDomainDefaultsKey))
    }

    static func descriptor(for id: ScaffoldSampleDomainID) -> ScaffoldSampleDomainDescriptor? {
        all.first { $0.id == id }
    }

    static func descriptor(forRawValue rawValue: String?) -> ScaffoldSampleDomainDescriptor {
        guard let rawValue,
              let id = ScaffoldSampleDomainID(rawValue: rawValue),
              let descriptor = descriptor(for: id) else {
            return defaultDomain
        }
        return descriptor
    }

    static func registerSelectedTools(in registry: ToolRegistry = .shared) {
        registry.removeAll()
        selectedDomain.toolProvider.registerTools(in: registry)
    }

    static func selectedToolNames() -> [String] {
        selectedDomain.toolProvider.toolNames
    }

    static func registerSchemas() {
        all.forEach { $0.registerSchema() }
    }

    static func registerTools(in registry: ToolRegistry = .shared) {
        all.forEach { $0.toolProvider.registerTools(in: registry) }
    }

    @discardableResult
    static func switchToDomain(
        rawValue: String,
        seedRawFacts: Bool = true
    ) throws -> ScaffoldSampleDomainSeedResult? {
        let domain = descriptor(forRawValue: rawValue)
        try clearAllSampleFacts()
        UserDefaults.standard.set(domain.id.rawValue, forKey: selectedDomainDefaultsKey)
        domain.registerSchema()
        registerSelectedTools()
        guard seedRawFacts else { return try domain.stats() }
        return try domain.seedRawFacts()
    }

    @discardableResult
    static func clearAllSampleFacts() throws -> Int {
        let namespaces = all.map(\.namespace)
        guard !namespaces.isEmpty else { return 0 }

        let dbURL = documentsURL().appendingPathComponent("edge_data.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return 0 }

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try dbQueue.write { db in
            let placeholders = Array(repeating: "?", count: namespaces.count).joined(separator: ", ")
            let arguments = StatementArguments(namespaces)
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM facts WHERE namespace IN (\(placeholders))",
                arguments: arguments
            ) ?? 0
            try db.execute(
                sql: "DELETE FROM facts WHERE namespace IN (\(placeholders))",
                arguments: StatementArguments(namespaces)
            )
            return count
        }
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }
}

private struct ScaffoldFinanceToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldTooling.allToolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldTooling.registerTools(in: registry)
    }
}

private struct ScaffoldHealthToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldHealthTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldHealthTooling.registerTools(in: registry)
    }
}

private struct ScaffoldReadingToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldReadingTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldReadingTooling.registerTools(in: registry)
    }
}

private struct ScaffoldJournalToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldJournalTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldJournalTooling.registerTools(in: registry)
    }
}

private struct ScaffoldTravelToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldTravelTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldTravelTooling.registerTools(in: registry)
    }
}

private struct ScaffoldCookingToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldCookingTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldCookingTooling.registerTools(in: registry)
    }
}

private struct ScaffoldMusicToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldMusicTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldMusicTooling.registerTools(in: registry)
    }
}

private struct ScaffoldWorkToolProvider: ScaffoldSampleDomainToolProviding {
    let toolNames = ScaffoldWorkTooling.toolNames

    func registerTools(in registry: ToolRegistry) {
        ScaffoldWorkTooling.registerTools(in: registry)
    }
}

extension ScaffoldSampleDomainDescriptor {
    static var finance: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .finance,
            displayName: "Finance",
            namespace: ScaffoldFinanceSample.namespace,
            schemaName: ScaffoldFinanceSample.schemaName,
            resourceName: ScaffoldFinanceSample.resourceName,
            rppDirectionSetID: "finance_consumer",
            summary: "Synthetic personal finance facts for Neural Imprint, RPP, classification, and read-only tool demos.",
            toolProvider: ScaffoldFinanceToolProvider(),
            registerSchema: {
                ScaffoldFinanceSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldFinanceSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldFinanceSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldFinanceSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldFinanceSample.stats())
            }
        )
    }

    static var health: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .health,
            displayName: "Health & Fitness",
            namespace: ScaffoldHealthSample.namespace,
            schemaName: ScaffoldHealthSample.schemaName,
            resourceName: ScaffoldHealthSample.resourceName,
            rppDirectionSetID: "health_fitness",
            summary: "Synthetic health and fitness facts for numeric trends, routines, injuries, recovery, and read-only tool demos.",
            toolProvider: ScaffoldHealthToolProvider(),
            registerSchema: {
                ScaffoldHealthSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldHealthSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldHealthSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldHealthSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldHealthSample.stats())
            }
        )
    }

    static var reading: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .reading,
            displayName: "Reading & Learning",
            namespace: ScaffoldReadingSample.namespace,
            schemaName: ScaffoldReadingSample.schemaName,
            resourceName: ScaffoldReadingSample.resourceName,
            rppDirectionSetID: "reading_learning",
            summary: "Synthetic reading and learning facts for long-text interests, progress, notes, language preference, and read-only tool demos.",
            toolProvider: ScaffoldReadingToolProvider(),
            registerSchema: {
                ScaffoldReadingSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldReadingSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldReadingSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldReadingSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldReadingSample.stats())
            }
        )
    }

    static var journal: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .journal,
            displayName: "Journal & Tasks",
            namespace: ScaffoldJournalSample.namespace,
            schemaName: ScaffoldJournalSample.schemaName,
            resourceName: ScaffoldJournalSample.resourceName,
            rppDirectionSetID: "journal_reflection",
            summary: "Synthetic journal, idea, task, reminder, and event facts for mood patterns, personal memory, task follow-up, and read-only tool demos.",
            toolProvider: ScaffoldJournalToolProvider(),
            registerSchema: {
                ScaffoldJournalSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldJournalSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldJournalSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldJournalSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldJournalSample.stats())
            }
        )
    }

    static var travel: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .travel,
            displayName: "Travel",
            namespace: ScaffoldTravelSample.namespace,
            schemaName: ScaffoldTravelSample.schemaName,
            resourceName: ScaffoldTravelSample.resourceName,
            rppDirectionSetID: "travel_explorer",
            summary: "Synthetic travel facts for itinerary memory, destinations, transit, hotels, dining while traveling, budgets, and read-only tool demos.",
            toolProvider: ScaffoldTravelToolProvider(),
            registerSchema: {
                ScaffoldTravelSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldTravelSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldTravelSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldTravelSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldTravelSample.stats())
            }
        )
    }

    static var cooking: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .cooking,
            displayName: "Cooking",
            namespace: ScaffoldCookingSample.namespace,
            schemaName: ScaffoldCookingSample.schemaName,
            resourceName: ScaffoldCookingSample.resourceName,
            rppDirectionSetID: "cooking_kitchen",
            summary: "Synthetic cooking, baking, grocery, recipe, and meal plan facts for food preference, kitchen routines, grocery spend, and read-only tool demos.",
            toolProvider: ScaffoldCookingToolProvider(),
            registerSchema: {
                ScaffoldCookingSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldCookingSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldCookingSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldCookingSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldCookingSample.stats())
            }
        )
    }

    static var music: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .music,
            displayName: "Music & Media",
            namespace: ScaffoldMusicSample.namespace,
            schemaName: ScaffoldMusicSample.schemaName,
            resourceName: ScaffoldMusicSample.resourceName,
            rppDirectionSetID: "music_media",
            summary: "Synthetic music, video, movie, podcast, and TV facts for media preference, mood, listening time, and read-only tool demos.",
            toolProvider: ScaffoldMusicToolProvider(),
            registerSchema: {
                ScaffoldMusicSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldMusicSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldMusicSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldMusicSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldMusicSample.stats())
            }
        )
    }

    static var work: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainDescriptor(
            id: .work,
            displayName: "Work",
            namespace: ScaffoldWorkSample.namespace,
            schemaName: ScaffoldWorkSample.schemaName,
            resourceName: ScaffoldWorkSample.resourceName,
            rppDirectionSetID: "work_productivity",
            summary: "Synthetic work records for projects, meetings, commits, blockers, workload, status tracking, and read-only tool demos.",
            toolProvider: ScaffoldWorkToolProvider(),
            registerSchema: {
                ScaffoldWorkSample.registerSchema()
            },
            loadRecordCount: {
                try ScaffoldWorkSample.loadRecords().count
            },
            seedRawFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldWorkSample.seedRawFacts(limit: limit))
            },
            seedClassifiedFacts: { limit in
                try ScaffoldSampleDomainSeedResult(ScaffoldWorkSample.seedClassifiedFacts(limit: limit))
            },
            stats: {
                try ScaffoldSampleDomainSeedResult(ScaffoldWorkSample.stats())
            }
        )
    }
}

private extension ScaffoldSampleDomainSeedResult {
    init(_ result: ScaffoldFinanceSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldHealthSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldReadingSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldJournalSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldTravelSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldCookingSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldMusicSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }

    init(_ result: ScaffoldWorkSample.SeedResult) {
        self.init(
            sampleRecords: result.sampleRecords,
            writtenThisRun: result.writtenThisRun,
            rawUnclassified: result.rawUnclassified,
            classified: result.classified,
            total: result.total
        )
    }
}
