// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldWorkTooling {
    static let recordsToolName = "query_work_records"
    static let summaryToolName = "query_work_summary"

    static let toolNames = [
        recordsToolName,
        summaryToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: recordsToolName,
                description: "Query synthetic work records by project, category, status, priority, participants, title, tags, blockers, note text, or date range. Use for exact meetings, standups, reviews, commits, milestones, blockers, latest/recent records, and evidence examples.",
                argumentsSchema: .jsonSchema(recordsArgumentsSchema),
                resultSchema: .jsonSchema(workQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact]
            ),
            executor: { arguments in
                try exportRecords(arguments: arguments)
            }
        ))

        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: summaryToolName,
                description: "Aggregate synthetic work time by project, category, record type, status, priority, or date range. Use for exact workload totals, meeting time, current/last period summaries, counts, project activity, and blocker summaries.",
                argumentsSchema: .jsonSchema(summaryArgumentsSchema),
                resultSchema: .jsonSchema(workQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportSummary(arguments: arguments)
            }
        ))
    }

    private static func exportRecords(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let project = stringValue(arguments["project"])?.lowercased()
        let category = stringValue(arguments["category"])?.lowercased()
        let status = stringValue(arguments["status"])?.lowercased()
        let priority = stringValue(arguments["priority"])?.lowercased()
        let participants = stringValue(arguments["participants"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let text = stringValue(arguments["text"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try workFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let project, !(item.project?.lowercased().contains(project) ?? false) { return false }
            if let category, item.category?.lowercased() != category { return false }
            if let status, item.status?.lowercased() != status { return false }
            if let priority, item.priority?.lowercased() != priority { return false }
            if let participants, !(item.participants?.lowercased().contains(participants) ?? false) { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let text, !item.searchText.lowercased().contains(text) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(WorkQueryResult(
            namespace: ScaffoldWorkSample.namespace,
            schema: ScaffoldWorkSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportSummary(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let project = stringValue(arguments["project"])?.lowercased()
        let category = stringValue(arguments["category"])?.lowercased()
        let status = stringValue(arguments["status"])?.lowercased()
        let priority = stringValue(arguments["priority"])?.lowercased()
        let minDuration = doubleValue(arguments["min_duration_minutes"] ?? arguments["minDurationMinutes"])
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try workFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let project, !(item.project?.lowercased().contains(project) ?? false) { return false }
            if let category, item.category?.lowercased() != category { return false }
            if let status, item.status?.lowercased() != status { return false }
            if let priority, item.priority?.lowercased() != priority { return false }
            if let minDuration, (item.durationMinutes ?? 0) < minDuration { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(WorkQueryResult(
            namespace: ScaffoldWorkSample.namespace,
            schema: ScaffoldWorkSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func workFacts() throws -> [WorkFact] {
        try Edge.queryFacts(
            namespace: ScaffoldWorkSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(WorkFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [WorkFact]) -> [WorkGroupSummary] {
        var groups: [String: WorkGroupSummary] = [:]
        for fact in facts {
            let key = fact.recordType
            var current = groups[key] ?? WorkGroupSummary(
                key: key,
                count: 0,
                totalDurationMinutes: 0
            )
            current.count += 1
            current.totalDurationMinutes += fact.durationMinutes ?? 0
            groups[key] = current
        }
        return groups.values
            .sorted { lhs, rhs in
                if lhs.totalDurationMinutes == rhs.totalDurationMinutes { return lhs.key < rhs.key }
                return lhs.totalDurationMinutes > rhs.totalDurationMinutes
            }
            .prefix(8)
            .map(\.rounded)
    }

    private static func boundedLimit(
        from value: AuditValue?,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        let raw: Int
        switch value {
        case .int(let value):
            raw = value
        case .double(let value):
            raw = Int(value)
        case .string(let value):
            raw = Int(value) ?? defaultValue
        default:
            raw = defaultValue
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private static func stringValue(_ value: AuditValue?) -> String? {
        guard case .string(let string) = value, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func doubleValue(_ value: AuditValue?) -> Double? {
        switch value {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    fileprivate static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolRegistryError.outputEncodingFailed
        }
        return text
    }

    private static let recordsArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["meeting", "review", "standup", "code_commit", "one_on_one", "retrospective", "learning", "milestone"],
          "description": "Optional work record type filter."
        },
        "project": { "type": "string", "description": "Optional project substring." },
        "category": {
          "type": "string",
          "enum": ["engineering", "infrastructure", "management", "product", "research"],
          "description": "Optional category filter."
        },
        "status": {
          "type": "string",
          "enum": ["blocked", "cancelled", "done", "in_progress"],
          "description": "Optional status filter."
        },
        "priority": {
          "type": "string",
          "enum": ["high", "medium", "low"],
          "description": "Optional priority filter."
        },
        "participants": { "type": "string", "description": "Optional participants substring." },
        "tags": { "type": "string", "description": "Optional tags substring." },
        "text": { "type": "string", "description": "Optional search text across title, project, participants, tags, outcome, note, and blockers." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let summaryArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["meeting", "review", "standup", "code_commit", "one_on_one", "retrospective", "learning", "milestone"],
          "description": "Optional work record type filter."
        },
        "project": { "type": "string", "description": "Optional project substring." },
        "category": {
          "type": "string",
          "enum": ["engineering", "infrastructure", "management", "product", "research"],
          "description": "Optional category filter."
        },
        "status": {
          "type": "string",
          "enum": ["blocked", "cancelled", "done", "in_progress"],
          "description": "Optional status filter."
        },
        "priority": {
          "type": "string",
          "enum": ["high", "medium", "low"],
          "description": "Optional priority filter."
        },
        "min_duration_minutes": { "type": "number", "description": "Optional minimum duration filter." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let workQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_duration_minutes": { "type": "number" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "total_duration_minutes", "items"]
    }
    """
}

private struct WorkFact {
    let date: String
    let recordType: String
    let title: String
    let project: String?
    let category: String?
    let durationMinutes: Double?
    let participants: String?
    let status: String?
    let priority: String?
    let tags: String?
    let outcome: String?
    let note: String?
    let blockers: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldWorkSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let title = fact.payload["title"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.title = title
        self.project = fact.payload["project"] as? String
        self.category = fact.payload["category"] as? String
        self.durationMinutes = fact.payload["duration_minutes"] as? Double
        self.participants = fact.payload["participants"] as? String
        self.status = fact.payload["status"] as? String
        self.priority = fact.payload["priority"] as? String
        self.tags = fact.payload["tags"] as? String
        self.outcome = fact.payload["outcome"] as? String
        self.note = fact.payload["note"] as? String
        self.blockers = fact.payload["blockers"] as? String
        self.tsMs = fact.tsMs
    }

    var searchText: String {
        [
            title,
            project,
            category,
            participants,
            status,
            priority,
            tags,
            outcome,
            note,
            blockers,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var item: WorkRecordItem {
        WorkRecordItem(
            date: date,
            recordType: recordType,
            title: title,
            project: project,
            category: category,
            durationMinutes: durationMinutes,
            participants: participants,
            status: status,
            priority: priority,
            tags: tags,
            outcome: outcome,
            note: note,
            blockers: blockers
        )
    }
}

private struct WorkQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalDurationMinutes: Double
    let groups: [WorkGroupSummary]
    let items: [WorkRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalDurationMinutes = "total_duration_minutes"
        case groups
        case items
    }
}

private struct WorkRecordItem: Codable {
    let date: String
    let recordType: String
    let title: String
    let project: String?
    let category: String?
    let durationMinutes: Double?
    let participants: String?
    let status: String?
    let priority: String?
    let tags: String?
    let outcome: String?
    let note: String?
    let blockers: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case title
        case project
        case category
        case durationMinutes = "duration_minutes"
        case participants
        case status
        case priority
        case tags
        case outcome
        case note
        case blockers
    }
}

private struct WorkGroupSummary: Codable {
    let key: String
    var count: Int
    var totalDurationMinutes: Double

    var rounded: WorkGroupSummary {
        WorkGroupSummary(
            key: key,
            count: count,
            totalDurationMinutes: ScaffoldWorkTooling.rounded(totalDurationMinutes)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalDurationMinutes = "total_duration_minutes"
    }
}
