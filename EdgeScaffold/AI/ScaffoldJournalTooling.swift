// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldJournalTooling {
    static let journalToolName = "query_journal"
    static let tasksToolName = "query_tasks"

    static let toolNames = [
        journalToolName,
        tasksToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: journalToolName,
                description: "Query synthetic journal, idea, and event entries by mood, tags, people, title, body text, or date range. Use for exact diary memories, latest/recent events, idea evidence, people mentions, and date-range journal lookups.",
                argumentsSchema: .jsonSchema(journalArgumentsSchema),
                resultSchema: .jsonSchema(journalQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact]
            ),
            executor: { arguments in
                try exportJournal(arguments: arguments)
            }
        ))

        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: tasksToolName,
                description: "Query synthetic task, reminder, and event records by status, priority, tags, title, or date range. Use for exact pending tasks, high-priority tasks, latest/recent reminders, completion counts, and date-range todo lookups.",
                argumentsSchema: .jsonSchema(tasksArgumentsSchema),
                resultSchema: .jsonSchema(journalQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportTasks(arguments: arguments)
            }
        ))
    }

    private static func exportJournal(arguments: [String: AuditValue]) throws -> String {
        let mood = stringValue(arguments["mood"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let title = stringValue(arguments["title"])?.lowercased()
        let text = stringValue(arguments["text"])?.lowercased()
        let people = stringValue(arguments["people"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try journalFacts()
        let filtered = allFacts.filter { item in
            if !["journal", "idea", "event"].contains(item.recordType) { return false }
            if let mood, item.mood?.lowercased() != mood { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let title, !item.title.lowercased().contains(title) { return false }
            if let text, !(item.body?.lowercased().contains(text) ?? false) { return false }
            if let people, !(item.people?.lowercased().contains(people) ?? false) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(JournalQueryResult(
            namespace: ScaffoldJournalSample.namespace,
            schema: ScaffoldJournalSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportTasks(arguments: [String: AuditValue]) throws -> String {
        let status = stringValue(arguments["status"])?.lowercased()
        let priority = stringValue(arguments["priority"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let title = stringValue(arguments["title"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try journalFacts()
        let filtered = allFacts.filter { item in
            if !["task", "reminder", "event"].contains(item.recordType) { return false }
            if let status, item.status?.lowercased() != status { return false }
            if let priority, item.priority?.lowercased() != priority { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let title, !item.title.lowercased().contains(title) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(JournalQueryResult(
            namespace: ScaffoldJournalSample.namespace,
            schema: ScaffoldJournalSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func journalFacts() throws -> [JournalFact] {
        try Edge.queryFacts(
            namespace: ScaffoldJournalSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(JournalFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [JournalFact]) -> [JournalGroupSummary] {
        var groups: [String: JournalGroupSummary] = [:]
        for fact in facts {
            let key = fact.recordType
            var current = groups[key] ?? JournalGroupSummary(key: key, count: 0)
            current.count += 1
            groups[key] = current
        }
        return groups.values
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.key < rhs.key }
                return lhs.count > rhs.count
            }
            .prefix(8)
            .map { $0 }
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

    private static func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolRegistryError.outputEncodingFailed
        }
        return text
    }

    private static let journalArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "mood": {
          "type": "string",
          "enum": ["happy", "calm", "focused", "anxious", "tired", "excited", "frustrated", "grateful"],
          "description": "Optional mood filter."
        },
        "tags": {
          "type": "string",
          "description": "Optional tags substring."
        },
        "title": {
          "type": "string",
          "description": "Optional title substring."
        },
        "text": {
          "type": "string",
          "description": "Optional body text substring."
        },
        "people": {
          "type": "string",
          "description": "Optional people substring."
        },
        "start_date": {
          "type": "string",
          "description": "Optional absolute start date in YYYY-MM-DD."
        },
        "end_date": {
          "type": "string",
          "description": "Optional absolute end date in YYYY-MM-DD."
        },
        "limit": {
          "type": "integer",
          "description": "Maximum records to return."
        }
      },
      "additionalProperties": false
    }
    """

    private static let tasksArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "status": {
          "type": "string",
          "enum": ["pending", "done", "cancelled"],
          "description": "Optional task status filter."
        },
        "priority": {
          "type": "string",
          "enum": ["high", "medium", "low"],
          "description": "Optional task priority filter."
        },
        "tags": {
          "type": "string",
          "description": "Optional tags substring."
        },
        "title": {
          "type": "string",
          "description": "Optional title substring."
        },
        "start_date": {
          "type": "string",
          "description": "Optional absolute start date in YYYY-MM-DD."
        },
        "end_date": {
          "type": "string",
          "description": "Optional absolute end date in YYYY-MM-DD."
        },
        "limit": {
          "type": "integer",
          "description": "Maximum records to return."
        }
      },
      "additionalProperties": false
    }
    """

    private static let journalQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "items"]
    }
    """
}

private struct JournalFact {
    let date: String
    let recordType: String
    let title: String
    let body: String?
    let mood: String?
    let energy: String?
    let tags: String?
    let priority: String?
    let status: String?
    let location: String?
    let people: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldJournalSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let title = fact.payload["title"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.title = title
        self.body = fact.payload["body"] as? String
        self.mood = fact.payload["mood"] as? String
        self.energy = fact.payload["energy"] as? String
        self.tags = fact.payload["tags"] as? String
        self.priority = fact.payload["priority"] as? String
        self.status = fact.payload["status"] as? String
        self.location = fact.payload["location"] as? String
        self.people = fact.payload["people"] as? String
        self.tsMs = fact.tsMs
    }

    var item: JournalRecordItem {
        JournalRecordItem(
            date: date,
            recordType: recordType,
            title: title,
            body: body,
            mood: mood,
            energy: energy,
            tags: tags,
            priority: priority,
            status: status,
            location: location,
            people: people
        )
    }
}

private struct JournalQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let groups: [JournalGroupSummary]
    let items: [JournalRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case groups
        case items
    }
}

private struct JournalRecordItem: Codable {
    let date: String
    let recordType: String
    let title: String
    let body: String?
    let mood: String?
    let energy: String?
    let tags: String?
    let priority: String?
    let status: String?
    let location: String?
    let people: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case title
        case body
        case mood
        case energy
        case tags
        case priority
        case status
        case location
        case people
    }
}

private struct JournalGroupSummary: Codable {
    let key: String
    var count: Int
}
