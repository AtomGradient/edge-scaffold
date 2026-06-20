// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldReadingTooling {
    static let readingHistoryToolName = "query_reading_history"
    static let notesToolName = "query_notes"

    static let toolNames = [
        readingHistoryToolName,
        notesToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: readingHistoryToolName,
                description: "Query synthetic reading and learning history by category, record type, author, title, language, or date range. Use for exact reading records, latest/recent items, progress, counts, learning history, and date-range reading summaries.",
                argumentsSchema: .jsonSchema(readingHistoryArgumentsSchema),
                resultSchema: .jsonSchema(readingQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportReadingHistory(arguments: arguments)
            }
        ))

        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: notesToolName,
                description: "Query synthetic reading notes, highlights, and excerpts by title, tags, category, or date range. Use for exact note text, evidence, quotes, latest highlights, and date-range note lookups.",
                argumentsSchema: .jsonSchema(notesArgumentsSchema),
                resultSchema: .jsonSchema(readingQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact]
            ),
            executor: { arguments in
                try exportNotes(arguments: arguments)
            }
        ))
    }

    private static func exportReadingHistory(arguments: [String: AuditValue]) throws -> String {
        let category = stringValue(arguments["category"])?.lowercased()
        let recordType = stringValue(arguments["record_type"])?.lowercased()
        let author = stringValue(arguments["author"])?.lowercased()
        let title = stringValue(arguments["title"])?.lowercased()
        let language = stringValue(arguments["language"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try readingFacts()
        let filtered = allFacts.filter { item in
            if let category, item.category?.lowercased() != category { return false }
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let author, !(item.author?.lowercased().contains(author) ?? false) { return false }
            if let title, !item.title.lowercased().contains(title) { return false }
            if let language, item.language?.lowercased() != language { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(ReadingQueryResult(
            namespace: ScaffoldReadingSample.namespace,
            schema: ScaffoldReadingSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            totalPagesRead: rounded(filtered.compactMap(\.pagesRead).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportNotes(arguments: [String: AuditValue]) throws -> String {
        let title = stringValue(arguments["title"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let category = stringValue(arguments["category"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try readingFacts()
        let filtered = allFacts.filter { item in
            let hasNoteLikeText = item.recordType == "note" || item.note != nil || item.highlight != nil
            guard hasNoteLikeText else { return false }
            if let title, !item.title.lowercased().contains(title) { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let category, item.category?.lowercased() != category { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(ReadingQueryResult(
            namespace: ScaffoldReadingSample.namespace,
            schema: ScaffoldReadingSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            totalPagesRead: rounded(filtered.compactMap(\.pagesRead).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func readingFacts() throws -> [ReadingFact] {
        try Edge.queryFacts(
            namespace: ScaffoldReadingSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(ReadingFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [ReadingFact]) -> [ReadingGroupSummary] {
        var groups: [String: ReadingGroupSummary] = [:]
        for fact in facts {
            let key = fact.category ?? "uncategorized"
            var current = groups[key] ?? ReadingGroupSummary(
                key: key,
                count: 0,
                totalDurationMinutes: 0,
                totalPagesRead: 0
            )
            current.count += 1
            current.totalDurationMinutes += fact.durationMinutes ?? 0
            current.totalPagesRead += fact.pagesRead ?? 0
            groups[key] = current
        }
        return groups.values
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.key < rhs.key }
                return lhs.count > rhs.count
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

    private static func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolRegistryError.outputEncodingFailed
        }
        return text
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let readingHistoryArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "category": {
          "type": "string",
          "enum": ["tech", "science", "fiction", "business", "philosophy", "history", "self_help", "language", "design", "other"],
          "description": "Optional reading category filter."
        },
        "record_type": {
          "type": "string",
          "enum": ["book", "article", "course", "podcast", "note"],
          "description": "Optional reading record type filter."
        },
        "author": {
          "type": "string",
          "description": "Optional author substring."
        },
        "title": {
          "type": "string",
          "description": "Optional title substring."
        },
        "language": {
          "type": "string",
          "enum": ["zh", "en", "ja"],
          "description": "Optional language code."
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

    private static let notesArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "Optional title substring."
        },
        "tags": {
          "type": "string",
          "description": "Optional tags substring."
        },
        "category": {
          "type": "string",
          "enum": ["tech", "science", "fiction", "business", "philosophy", "history", "self_help", "language", "design", "other"],
          "description": "Optional category filter."
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

    private static let readingQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_duration_minutes": { "type": "number" },
        "total_pages_read": { "type": "number" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "items"]
    }
    """
}

private struct ReadingFact {
    let date: String
    let recordType: String
    let title: String
    let author: String?
    let category: String?
    let pagesRead: Double?
    let durationMinutes: Double?
    let progressPercent: Double?
    let rating: Double?
    let tags: String?
    let highlight: String?
    let note: String?
    let language: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldReadingSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let title = fact.payload["title"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.title = title
        self.author = fact.payload["author"] as? String
        self.category = fact.payload["category"] as? String
        self.pagesRead = Self.double(fact.payload["pages_read"])
        self.durationMinutes = Self.double(fact.payload["duration_minutes"])
        self.progressPercent = Self.double(fact.payload["progress_percent"])
        self.rating = Self.double(fact.payload["rating"])
        self.tags = fact.payload["tags"] as? String
        self.highlight = fact.payload["highlight"] as? String
        self.note = fact.payload["note"] as? String
        self.language = fact.payload["language"] as? String
        self.tsMs = fact.tsMs
    }

    var item: ReadingRecordItem {
        ReadingRecordItem(
            date: date,
            recordType: recordType,
            title: title,
            author: author,
            category: category,
            pagesRead: pagesRead,
            durationMinutes: durationMinutes,
            progressPercent: progressPercent,
            rating: rating,
            tags: tags,
            highlight: highlight,
            note: note,
            language: language
        )
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}

private struct ReadingQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalDurationMinutes: Double
    let totalPagesRead: Double
    let groups: [ReadingGroupSummary]
    let items: [ReadingRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalDurationMinutes = "total_duration_minutes"
        case totalPagesRead = "total_pages_read"
        case groups
        case items
    }
}

private struct ReadingRecordItem: Codable {
    let date: String
    let recordType: String
    let title: String
    let author: String?
    let category: String?
    let pagesRead: Double?
    let durationMinutes: Double?
    let progressPercent: Double?
    let rating: Double?
    let tags: String?
    let highlight: String?
    let note: String?
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case title
        case author
        case category
        case pagesRead = "pages_read"
        case durationMinutes = "duration_minutes"
        case progressPercent = "progress_percent"
        case rating
        case tags
        case highlight
        case note
        case language
    }
}

private struct ReadingGroupSummary: Codable {
    let key: String
    var count: Int
    var totalDurationMinutes: Double
    var totalPagesRead: Double

    var rounded: ReadingGroupSummary {
        ReadingGroupSummary(
            key: key,
            count: count,
            totalDurationMinutes: (totalDurationMinutes * 100).rounded() / 100,
            totalPagesRead: (totalPagesRead * 100).rounded() / 100
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalDurationMinutes = "total_duration_minutes"
        case totalPagesRead = "total_pages_read"
    }
}
