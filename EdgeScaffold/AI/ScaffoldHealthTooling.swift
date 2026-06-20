// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldHealthTooling {
    static let workoutToolName = "query_workouts"
    static let healthMetricsToolName = "query_health_metrics"

    static let toolNames = [
        workoutToolName,
        healthMetricsToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: workoutToolName,
                description: "Query synthetic health workout facts for activities, duration, calories, locations, trends, and date ranges. Use for exact workout records, latest/recent sessions, activity counts, durations, calories, and date-range workout summaries.",
                argumentsSchema: .jsonSchema(workoutArgumentsSchema),
                resultSchema: .jsonSchema(healthQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportWorkouts(arguments: arguments)
            }
        ))

        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: healthMetricsToolName,
                description: "Query synthetic health measurements, symptoms, medication, and appointments. Use for exact weight, blood pressure, heart rate, sleep, injury, recovery, symptom, medication, appointment, current/last period, and date-range health questions.",
                argumentsSchema: .jsonSchema(healthMetricsArgumentsSchema),
                resultSchema: .jsonSchema(healthQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportHealthMetrics(arguments: arguments)
            }
        ))
    }

    private static func exportWorkouts(arguments: [String: AuditValue]) throws -> String {
        let activity = stringValue(arguments["activity"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let minDuration = doubleValue(arguments["duration_min"] ?? arguments["min_duration_minutes"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try healthFacts()
        let filtered = allFacts.filter { item in
            guard item.recordType == "workout" else { return false }
            if let activity, !item.activity.lowercased().contains(activity) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            if let minDuration, (item.durationMinutes ?? 0) < minDuration { return false }
            return true
        }

        return try encodeToolResult(HealthQueryResult(
            namespace: ScaffoldHealthSample.namespace,
            schema: ScaffoldHealthSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            totalCalories: rounded(filtered.compactMap(\.calories).reduce(0, +)),
            groups: grouped(filtered, by: \.activity),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportHealthMetrics(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"])?.lowercased()
        let metricType = stringValue(arguments["metric_type"])?.lowercased()
        let activity = stringValue(arguments["activity"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try healthFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let metricType, !item.activity.lowercased().contains(metricType) { return false }
            if let activity, !item.activity.lowercased().contains(activity) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(HealthQueryResult(
            namespace: ScaffoldHealthSample.namespace,
            schema: ScaffoldHealthSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            totalCalories: rounded(filtered.compactMap(\.calories).reduce(0, +)),
            groups: grouped(filtered, by: \.activity),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func healthFacts() throws -> [HealthFact] {
        try Edge.queryFacts(
            namespace: ScaffoldHealthSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(HealthFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(
        _ facts: [HealthFact],
        by keyPath: KeyPath<HealthFact, String>
    ) -> [HealthGroupSummary] {
        var groups: [String: HealthGroupSummary] = [:]
        for fact in facts {
            let key = fact[keyPath: keyPath]
            var current = groups[key] ?? HealthGroupSummary(
                key: key,
                count: 0,
                totalDurationMinutes: 0,
                totalCalories: 0
            )
            current.count += 1
            current.totalDurationMinutes += fact.durationMinutes ?? 0
            current.totalCalories += fact.calories ?? 0
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

    private static let workoutArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "activity": {
          "type": "string",
          "description": "Optional activity substring, for example 跑步, 力量训练, 游泳."
        },
        "start_date": {
          "type": "string",
          "description": "Optional absolute start date in YYYY-MM-DD."
        },
        "end_date": {
          "type": "string",
          "description": "Optional absolute end date in YYYY-MM-DD."
        },
        "duration_min": {
          "type": "number",
          "description": "Optional minimum workout duration in minutes."
        },
        "limit": {
          "type": "integer",
          "description": "Maximum records to return."
        }
      },
      "additionalProperties": false
    }
    """

    private static let healthMetricsArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["workout", "measurement", "medication", "appointment", "symptom"],
          "description": "Optional health record type filter."
        },
        "metric_type": {
          "type": "string",
          "description": "Optional metric/activity substring, for example 每日称重, 血压, 心率, 失眠."
        },
        "activity": {
          "type": "string",
          "description": "Optional activity substring."
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

    private static let healthQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_duration_minutes": { "type": "number" },
        "total_calories": { "type": "number" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "items"]
    }
    """
}

private struct HealthFact {
    let date: String
    let recordType: String
    let activity: String
    let durationMinutes: Double?
    let calories: Double?
    let value: Double?
    let unit: String?
    let location: String?
    let note: String?
    let mood: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldHealthSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let activity = fact.payload["activity"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.activity = activity
        self.durationMinutes = Self.double(fact.payload["duration_minutes"])
        self.calories = Self.double(fact.payload["calories"])
        self.value = Self.double(fact.payload["value"])
        self.unit = fact.payload["unit"] as? String
        self.location = fact.payload["location"] as? String
        self.note = fact.payload["note"] as? String
        self.mood = fact.payload["mood"] as? String
        self.tsMs = fact.tsMs
    }

    var item: HealthRecordItem {
        HealthRecordItem(
            date: date,
            recordType: recordType,
            activity: activity,
            durationMinutes: durationMinutes,
            calories: calories,
            value: value,
            unit: unit,
            location: location,
            mood: mood,
            note: note
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

private struct HealthQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalDurationMinutes: Double
    let totalCalories: Double
    let groups: [HealthGroupSummary]
    let items: [HealthRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalDurationMinutes = "total_duration_minutes"
        case totalCalories = "total_calories"
        case groups
        case items
    }
}

private struct HealthRecordItem: Codable {
    let date: String
    let recordType: String
    let activity: String
    let durationMinutes: Double?
    let calories: Double?
    let value: Double?
    let unit: String?
    let location: String?
    let mood: String?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case activity
        case durationMinutes = "duration_minutes"
        case calories
        case value
        case unit
        case location
        case mood
        case note
    }
}

private struct HealthGroupSummary: Codable {
    let key: String
    var count: Int
    var totalDurationMinutes: Double
    var totalCalories: Double

    var rounded: HealthGroupSummary {
        HealthGroupSummary(
            key: key,
            count: count,
            totalDurationMinutes: (totalDurationMinutes * 100).rounded() / 100,
            totalCalories: (totalCalories * 100).rounded() / 100
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalDurationMinutes = "total_duration_minutes"
        case totalCalories = "total_calories"
    }
}
