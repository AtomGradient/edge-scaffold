// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldCookingTooling {
    static let recordsToolName = "query_cooking_records"
    static let spendingToolName = "query_cooking_spending"

    static let toolNames = [
        recordsToolName,
        spendingToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: recordsToolName,
                description: "Read-only cooking record lookup API. Returns concrete cooking, baking, recipe, grocery, and meal plan rows for explicit dish, cuisine, ingredient, tag, note text, difficulty, date, or record_type filters.",
                argumentsSchema: .jsonSchema(recordsArgumentsSchema),
                resultSchema: .jsonSchema(cookingQueryResultSchema),
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
                name: spendingToolName,
                description: "Read-only cooking cost aggregation API. Returns exact total_cost, counts, grouped numeric summaries, and date-range cost summaries for explicit record_type, cuisine, dish, ingredient, or date filters.",
                argumentsSchema: .jsonSchema(spendingArgumentsSchema),
                resultSchema: .jsonSchema(cookingQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportSpending(arguments: arguments)
            }
        ))
    }

    private static func exportRecords(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let dish = stringValue(arguments["dish"] ?? arguments["dish_name"] ?? arguments["dishName"])?.lowercased()
        let cuisine = stringValue(arguments["cuisine"])?.lowercased()
        let difficulty = stringValue(arguments["difficulty"])?.lowercased()
        let ingredients = stringValue(arguments["ingredients"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let text = stringValue(arguments["text"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try cookingFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let dish, !item.dishName.lowercased().contains(dish) { return false }
            if let cuisine, item.cuisine?.lowercased() != cuisine { return false }
            if let difficulty, item.difficulty?.lowercased() != difficulty { return false }
            if let ingredients, !(item.ingredients?.lowercased().contains(ingredients) ?? false) { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let text, !item.searchText.lowercased().contains(text) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(CookingQueryResult(
            namespace: ScaffoldCookingSample.namespace,
            schema: ScaffoldCookingSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalCost: rounded(filtered.compactMap(\.cost).reduce(0, +)),
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            currency: "CNY",
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportSpending(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let dish = stringValue(arguments["dish"] ?? arguments["dish_name"] ?? arguments["dishName"])?.lowercased()
        let cuisine = stringValue(arguments["cuisine"])?.lowercased()
        let ingredients = stringValue(arguments["ingredients"])?.lowercased()
        let minCost = doubleValue(arguments["min_cost"] ?? arguments["minCost"])
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try cookingFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let dish, !item.dishName.lowercased().contains(dish) { return false }
            if let cuisine, item.cuisine?.lowercased() != cuisine { return false }
            if let ingredients, !(item.ingredients?.lowercased().contains(ingredients) ?? false) { return false }
            if let minCost, (item.cost ?? 0) < minCost { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(CookingQueryResult(
            namespace: ScaffoldCookingSample.namespace,
            schema: ScaffoldCookingSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalCost: rounded(filtered.compactMap(\.cost).reduce(0, +)),
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            currency: "CNY",
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func cookingFacts() throws -> [CookingFact] {
        try Edge.queryFacts(
            namespace: ScaffoldCookingSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(CookingFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [CookingFact]) -> [CookingGroupSummary] {
        var groups: [String: CookingGroupSummary] = [:]
        for fact in facts {
            let key = fact.recordType
            var current = groups[key] ?? CookingGroupSummary(
                key: key,
                count: 0,
                totalCost: 0,
                totalDurationMinutes: 0
            )
            current.count += 1
            current.totalCost += fact.cost ?? 0
            current.totalDurationMinutes += fact.durationMinutes ?? 0
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
          "enum": ["grocery", "meal_plan", "cooking", "baking", "recipe_saved"],
          "description": "Optional cooking record type filter. grocery represents grocery shopping and ingredient purchase records."
        },
        "dish_name": { "type": "string", "description": "Optional dish name substring." },
        "cuisine": {
          "type": "string",
          "enum": ["chinese_home", "chinese_regional", "japanese", "korean", "southeast_asian", "western", "baking", "other"],
          "description": "Optional cuisine filter."
        },
        "difficulty": {
          "type": "string",
          "enum": ["easy", "medium", "hard"],
          "description": "Optional difficulty filter."
        },
        "ingredients": { "type": "string", "description": "Optional concrete ingredient name substring, for example egg, tomato, beef, flour, or chicken." },
        "tags": { "type": "string", "description": "Optional tags substring." },
        "text": { "type": "string", "description": "Optional search text across dish, ingredients, tags, note, and source." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let spendingArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["grocery", "meal_plan", "cooking", "baking", "recipe_saved"],
          "description": "Optional cooking record type filter. grocery represents grocery shopping and ingredient purchase records."
        },
        "dish_name": { "type": "string", "description": "Optional dish name substring." },
        "cuisine": {
          "type": "string",
          "enum": ["chinese_home", "chinese_regional", "japanese", "korean", "southeast_asian", "western", "baking", "other"],
          "description": "Optional cuisine filter."
        },
        "ingredients": { "type": "string", "description": "Optional concrete ingredient name substring, for example egg, tomato, beef, flour, or chicken." },
        "min_cost": { "type": "number", "description": "Optional minimum cost filter." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let cookingQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_cost": { "type": "number" },
        "total_duration_minutes": { "type": "number" },
        "currency": { "type": "string" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "total_cost", "currency", "items"]
    }
    """
}

private struct CookingFact {
    let date: String
    let recordType: String
    let dishName: String
    let cuisine: String?
    let difficulty: String?
    let durationMinutes: Double?
    let servings: Double?
    let ingredients: String?
    let cost: Double?
    let rating: Double?
    let tags: String?
    let note: String?
    let source: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldCookingSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let dishName = fact.payload["dish_name"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.dishName = dishName
        self.cuisine = fact.payload["cuisine"] as? String
        self.difficulty = fact.payload["difficulty"] as? String
        self.durationMinutes = fact.payload["duration_minutes"] as? Double
        self.servings = fact.payload["servings"] as? Double
        self.ingredients = fact.payload["ingredients"] as? String
        self.cost = fact.payload["cost"] as? Double
        self.rating = fact.payload["rating"] as? Double
        self.tags = fact.payload["tags"] as? String
        self.note = fact.payload["note"] as? String
        self.source = fact.payload["source"] as? String
        self.tsMs = fact.tsMs
    }

    var searchText: String {
        [
            dishName,
            cuisine,
            difficulty,
            ingredients,
            tags,
            note,
            source,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var item: CookingRecordItem {
        CookingRecordItem(
            date: date,
            recordType: recordType,
            dishName: dishName,
            cuisine: cuisine,
            difficulty: difficulty,
            durationMinutes: durationMinutes,
            servings: servings,
            ingredients: ingredients,
            cost: cost,
            rating: rating,
            tags: tags,
            note: note,
            source: source
        )
    }
}

private struct CookingQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalCost: Double
    let totalDurationMinutes: Double
    let currency: String
    let groups: [CookingGroupSummary]
    let items: [CookingRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalCost = "total_cost"
        case totalDurationMinutes = "total_duration_minutes"
        case currency
        case groups
        case items
    }
}

private struct CookingRecordItem: Codable {
    let date: String
    let recordType: String
    let dishName: String
    let cuisine: String?
    let difficulty: String?
    let durationMinutes: Double?
    let servings: Double?
    let ingredients: String?
    let cost: Double?
    let rating: Double?
    let tags: String?
    let note: String?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case dishName = "dish_name"
        case cuisine
        case difficulty
        case durationMinutes = "duration_minutes"
        case servings
        case ingredients
        case cost
        case rating
        case tags
        case note
        case source
    }
}

private struct CookingGroupSummary: Codable {
    let key: String
    var count: Int
    var totalCost: Double
    var totalDurationMinutes: Double

    var rounded: CookingGroupSummary {
        CookingGroupSummary(
            key: key,
            count: count,
            totalCost: ScaffoldCookingTooling.rounded(totalCost),
            totalDurationMinutes: ScaffoldCookingTooling.rounded(totalDurationMinutes)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalCost = "total_cost"
        case totalDurationMinutes = "total_duration_minutes"
    }
}
