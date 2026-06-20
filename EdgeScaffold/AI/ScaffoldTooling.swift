// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldTooling {
    static let activityHistoryToolName = "scaffold_activity_history"
    static let expenseSearchToolName = "sample_expense_search"
    static let expenseSummaryToolName = "sample_expense_summary"

    static let sampleChatToolNames = [
        expenseSearchToolName,
        expenseSummaryToolName,
    ]

    static let allToolNames = sampleChatToolNames

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: expenseSearchToolName,
                description: "Read-only finance ledger search API. Returns concrete transaction rows with merchant, date, record_type, category, amount, and currency fields.",
                argumentsSchema: .jsonSchema(expenseSearchArgumentsSchema),
                resultSchema: .jsonSchema(expenseSearchResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportExpenseSearch(arguments: arguments)
            }
        ))

        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: expenseSummaryToolName,
                description: "Read-only finance ledger aggregation API. Returns exact totals, counts, and grouped numeric summaries by month, category, record_type, or merchant.",
                argumentsSchema: .jsonSchema(expenseSummaryArgumentsSchema),
                resultSchema: .jsonSchema(expenseSummaryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.aggregateFact, .exactFact]
            ),
            executor: { arguments in
                try exportExpenseSummary(arguments: arguments)
            }
        ))

    }

    static func toolSchemaSnapshot(in registry: ToolRegistry = .shared) throws -> ToolSchemaSnapshot {
        try registry.toolSchemaSnapshot()
    }

    static func userVisibleSummary(for results: [ToolChatLoop.ToolResult]) -> String {
        let summaries = results.compactMap { summary(for: $0) }
        return summaries.joined(separator: "\n\n")
    }

    private static func summary(for result: ToolChatLoop.ToolResult) -> String? {
        switch result.name {
        case expenseSummaryToolName:
            return expenseSummaryText(result.result)
        case expenseSearchToolName:
            return expenseSearchText(result.result)
        default:
            return genericToolResultText(toolName: result.name, json: result.result)
        }
    }

    private static func genericToolResultText(toolName: String, json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        let namespace = stringValue(dict["namespace"]) ?? ScaffoldSampleDomainRegistry.selectedDomain.namespace
        let matchedCount = intValue(dict["matched_count"] ?? dict["matchedCount"])
        let totalClassified = intValue(dict["total_classified"] ?? dict["totalClassified"])

        if matchedCount == 0 {
            return "本地 \(namespace) 样本数据里没有找到匹配记录。"
        }

        var lines = ["已查询本地 \(namespace) 样本数据。"]
        if let matchedCount {
            var countLine = "匹配 \(matchedCount) 条"
            if let totalClassified {
                countLine += "，样本库共 \(totalClassified) 条"
            }
            lines.append(countLine + "。")
        }

        for key in [
            "total_amount", "total_duration_minutes", "total_calories",
            "total_pages_read", "total_minutes", "average_rating"
        ] {
            if let value = doubleValue(dict[key]), value != 0 {
                lines.append("\(key): \(formatNumber(value))。")
            }
        }

        if let groups = dict["groups"] as? [[String: Any]], !groups.isEmpty {
            let rendered = groups.prefix(5).compactMap(renderGroup).joined(separator: "，")
            if !rendered.isEmpty {
                lines.append("分组摘要：\(rendered)。")
            }
        }

        if let items = dict["items"] as? [[String: Any]], !items.isEmpty {
            let rendered = items.prefix(5).compactMap(renderItem)
            if !rendered.isEmpty {
                lines.append("代表记录：")
                lines.append(contentsOf: rendered.map { "- \($0)" })
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func renderGroup(_ group: [String: Any]) -> String? {
        guard let key = stringValue(group["key"] ?? group["name"] ?? group["category"] ?? group["record_type"]) else {
            return nil
        }
        var parts = [key]
        if let count = intValue(group["count"]) {
            parts.append("\(count) 条")
        }
        for metric in ["amount", "duration_minutes", "calories", "pages_read", "minutes"] {
            if let value = doubleValue(group[metric]), value != 0 {
                parts.append("\(formatNumber(value))")
                break
            }
        }
        return parts.joined(separator: " ")
    }

    private static func renderItem(_ item: [String: Any]) -> String? {
        let keys = [
            "date", "title", "merchant", "activity", "dish_name", "destination",
            "category", "record_type", "project", "genre", "note"
        ]
        let parts = keys.compactMap { key -> String? in
            guard let value = stringValue(item[key]) else { return nil }
            return value
        }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(5).joined(separator: " · ")
    }

    private static func expenseSummaryText(_ json: String) -> String? {
        guard let decoded = decode(ExpenseSummaryResult.self, from: json) else {
            return nil
        }
        guard decoded.matchedCount > 0 else {
            return "本地样本账本里没有找到匹配记录。"
        }

        let groups = decoded.groups
            .prefix(5)
            .map { "\($0.key) \(money($0.amount, decoded.currency))（\($0.count) 笔）" }
            .joined(separator: "，")

        var lines = [
            "已查询本地样本账本：匹配 \(decoded.matchedCount) 笔，总计 \(money(decoded.totalAmount, decoded.currency))。"
        ]
        if !groups.isEmpty {
            lines.append("按 \(decoded.groupBy) 汇总：\(groups)。")
        }
        if let expense = decoded.recordTypeTotals["expense"] {
            lines.append("其中支出合计 \(money(expense, decoded.currency))。")
        }
        return lines.joined(separator: "\n")
    }

    private static func expenseSearchText(_ json: String) -> String? {
        guard let decoded = decode(ExpenseSearchResult.self, from: json) else {
            return nil
        }
        guard decoded.matchedCount > 0 else {
            return "本地样本账本里没有找到匹配记录。"
        }

        let items = decoded.items.prefix(5).map { item in
            "- \(item.date) · \(item.merchant) · \(item.category) · \(money(item.amount, item.currency))"
        }
        var lines = [
            "已查询本地样本账本：匹配 \(decoded.matchedCount) 笔，总计 \(money(decoded.totalAmount, decoded.currency))，展示前 \(items.count) 笔。"
        ]
        if let expense = decoded.recordTypeTotals["expense"] {
            lines.append("其中支出合计 \(money(expense, decoded.currency))。")
        }
        return (lines + items).joined(separator: "\n")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func money(_ amount: Double, _ currency: String) -> String {
        let symbol = currency == "CNY" ? "¥" : "\(currency) "
        return "\(symbol)\(String(format: "%.2f", amount))"
    }

    private static func exportActivityHistory(arguments: [String: AuditValue]) throws -> String {
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 5, range: 1...20)
        let categoryFilter = stringValue(arguments["category"])?.lowercased()
        let facts = try Edge.queryFacts(
            namespace: ScaffoldDemoSchema.namespace,
            status: .classifiedOnly,
            limit: 50
        )

        var categoryCounts: [String: Int] = [:]
        var recent: [ActivityHistoryItem] = []
        for fact in facts {
            let category = (fact.payload["category"] as? String)?.lowercased() ?? "unknown"
            categoryCounts[category, default: 0] += 1
            if let categoryFilter, category != categoryFilter {
                continue
            }
            guard recent.count < limit else { continue }
            recent.append(ActivityHistoryItem(
                category: category,
                description: fact.payload["description"] as? String,
                confidence: fact.classificationConfidence,
                corrected: fact.classificationCorrectedAt != nil,
                tsMs: fact.tsMs
            ))
        }

        let result = ActivityHistoryResult(
            namespace: ScaffoldDemoSchema.namespace,
            schema: ScaffoldDemoSchema.schemaName,
            totalClassified: facts.count,
            categoryCounts: categoryCounts,
            recent: recent
        )
        let data = try JSONEncoder().encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolRegistryError.outputEncodingFailed
        }
        return text
    }

    private static func exportExpenseSearch(arguments: [String: AuditValue]) throws -> String {
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 10, range: 1...50)
        let month = stringValue(arguments["month"])?.lowercased()
        let category = stringValue(arguments["category"])?.lowercased()
        let recordType = stringValue(arguments["record_type"])?.lowercased()
        let merchant = stringValue(arguments["merchant"])?.lowercased()
        let startDate = stringValue(arguments["start_date"])
        let endDate = stringValue(arguments["end_date"])
        let minAmount = doubleValue(arguments["min_amount"])
        let maxAmount = doubleValue(arguments["max_amount"])

        let allFacts = try financeFacts()
        let filtered = allFacts.filter { item in
            if let month, item.month.lowercased() != month { return false }
            if let category, item.category.lowercased() != category { return false }
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let merchant, !item.merchant.lowercased().contains(merchant) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            if let minAmount, item.amount < minAmount { return false }
            if let maxAmount, item.amount > maxAmount { return false }
            return true
        }

        let totalAmount = filtered.reduce(0) { $0 + $1.amount }
        var recordTypeTotals: [String: Double] = [:]
        for item in filtered {
            recordTypeTotals[item.recordType, default: 0] += item.amount
        }

        let result = ExpenseSearchResult(
            namespace: ScaffoldFinanceSample.namespace,
            schema: ScaffoldFinanceSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalAmount: roundCurrency(totalAmount),
            currency: "CNY",
            recordTypeTotals: recordTypeTotals.mapValues(roundCurrency),
            items: Array(filtered.prefix(limit)).map(\.searchItem)
        )
        return try encodeToolResult(result)
    }

    private static func exportExpenseSummary(arguments: [String: AuditValue]) throws -> String {
        let month = stringValue(arguments["month"])?.lowercased()
        let category = stringValue(arguments["category"])?.lowercased()
        let recordType = stringValue(arguments["record_type"])?.lowercased()
        let groupBy = stringValue(arguments["group_by"])?.lowercased() ?? "category"
        let startDate = stringValue(arguments["start_date"])
        let endDate = stringValue(arguments["end_date"])

        let allFacts = try financeFacts()
        let filtered = allFacts.filter { item in
            if let month, item.month.lowercased() != month { return false }
            if let category, item.category.lowercased() != category { return false }
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        let totalAmount = filtered.reduce(0) { $0 + $1.amount }
        var grouped: [String: ExpenseGroupSummary] = [:]
        for item in filtered {
            let key: String
            switch groupBy {
            case "record_type": key = item.recordType
            case "month": key = item.month
            case "merchant": key = item.merchant
            default: key = item.category
            }
            var current = grouped[key] ?? ExpenseGroupSummary(key: key, count: 0, amount: 0)
            current.count += 1
            current.amount += item.amount
            grouped[key] = current
        }

        var recordTypeTotals: [String: Double] = [:]
        for item in filtered {
            recordTypeTotals[item.recordType, default: 0] += item.amount
        }

        let result = ExpenseSummaryResult(
            namespace: ScaffoldFinanceSample.namespace,
            schema: ScaffoldFinanceSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalAmount: roundCurrency(totalAmount),
            currency: "CNY",
            groupBy: groupBy,
            groups: grouped.values
                .sorted { $0.amount > $1.amount }
                .map { $0.rounded },
            recordTypeTotals: recordTypeTotals.mapValues(roundCurrency)
        )
        return try encodeToolResult(result)
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

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty:
            return value
        case let value as Int:
            return "\(value)"
        case let value as Double:
            return formatNumber(value)
        case let value as Bool:
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
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

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private static func financeFacts() throws -> [FinanceFact] {
        try Edge.queryFacts(
            namespace: ScaffoldFinanceSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(FinanceFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func encodeToolResult<T: Encodable>(_ result: T) throws -> String {
        let data = try JSONEncoder().encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolRegistryError.outputEncodingFailed
        }
        return text
    }

    private static func roundCurrency(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static let activityHistoryArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 20,
          "description": "Maximum number of recent classified records to return."
        },
        "category": {
          "type": "string",
          "description": "Optional lowercase category filter, such as dining, transport, shopping, or subscription."
        }
      },
      "additionalProperties": false
    }
    """

    private static let activityHistoryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "category_counts": {
          "type": "object",
          "additionalProperties": { "type": "integer" }
        },
        "recent": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "category": { "type": "string" },
              "description": { "type": "string" },
              "confidence": { "type": "number" },
              "corrected": { "type": "boolean" },
              "ts_ms": { "type": "integer" }
            },
            "required": ["category", "corrected", "ts_ms"]
          }
        }
      },
      "required": ["namespace", "schema", "total_classified", "category_counts", "recent"]
    }
    """

    private static let expenseSearchArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 50,
          "description": "Maximum number of matching records to return."
        },
        "month": {
          "type": "string",
          "description": "Optional month filter in YYYY-MM format, for example 2026-02."
        },
        "record_type": {
          "type": "string",
          "enum": ["expense", "income", "transfer", "refund"],
          "description": "Optional record type. Use expense for spending questions."
        },
        "category": {
          "type": "string",
          "enum": ["coffee", "dining", "transport", "groceries", "shopping", "entertainment", "education", "medical", "subscription", "utilities", "rent", "insurance", "salary", "freelance", "transfer_in", "transfer_out", "refund", "gift", "other"],
          "description": "Optional purpose category."
        },
        "merchant": {
          "type": "string",
          "description": "Optional case-insensitive merchant substring."
        },
        "min_amount": {
          "type": "number",
          "description": "Optional inclusive minimum amount."
        },
        "max_amount": {
          "type": "number",
          "description": "Optional inclusive maximum amount."
        }
      },
      "additionalProperties": false
    }
    """

    private static let expenseSearchResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_amount": { "type": "number" },
        "currency": { "type": "string" },
        "record_type_totals": {
          "type": "object",
          "additionalProperties": { "type": "number" }
        },
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string" },
              "date": { "type": "string" },
              "month": { "type": "string" },
              "record_type": { "type": "string" },
              "category": { "type": "string" },
              "merchant": { "type": "string" },
              "amount": { "type": "number" },
              "currency": { "type": "string" },
              "channel": { "type": "string" },
              "location": { "type": "string" },
              "note": { "type": "string" }
            },
            "required": ["id", "date", "month", "record_type", "category", "merchant", "amount", "currency"]
          }
        }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "total_amount", "currency", "record_type_totals", "items"]
    }
    """

    private static let expenseSummaryArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "month": {
          "type": "string",
          "description": "Optional month filter in YYYY-MM format."
        },
        "record_type": {
          "type": "string",
          "enum": ["expense", "income", "transfer", "refund"],
          "description": "Optional record type. Use expense for spending questions."
        },
        "category": {
          "type": "string",
          "enum": ["coffee", "dining", "transport", "groceries", "shopping", "entertainment", "education", "medical", "subscription", "utilities", "rent", "insurance", "salary", "freelance", "transfer_in", "transfer_out", "refund", "gift", "other"],
          "description": "Optional category filter."
        },
        "group_by": {
          "type": "string",
          "enum": ["category", "record_type", "month", "merchant"],
          "description": "Aggregation dimension. Defaults to category."
        }
      },
      "additionalProperties": false
    }
    """

    private static let expenseSummaryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_amount": { "type": "number" },
        "currency": { "type": "string" },
        "group_by": { "type": "string" },
        "groups": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "key": { "type": "string" },
              "count": { "type": "integer" },
              "amount": { "type": "number" }
            },
            "required": ["key", "count", "amount"]
          }
        },
        "record_type_totals": {
          "type": "object",
          "additionalProperties": { "type": "number" }
        }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "total_amount", "currency", "group_by", "groups", "record_type_totals"]
    }
    """

}

private struct ActivityHistoryResult: Encodable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let categoryCounts: [String: Int]
    let recent: [ActivityHistoryItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case categoryCounts = "category_counts"
        case recent
    }
}

private struct ActivityHistoryItem: Encodable {
    let category: String
    let description: String?
    let confidence: Double?
    let corrected: Bool
    let tsMs: Int64

    private enum CodingKeys: String, CodingKey {
        case category
        case description
        case confidence
        case corrected
        case tsMs = "ts_ms"
    }
}

private struct FinanceFact {
    let id: String
    let date: String
    let month: String
    let recordType: String
    let category: String
    let merchant: String
    let amount: Double
    let currency: String
    let channel: String?
    let location: String?
    let note: String?
    let timeOfDay: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard let recordType = fact.payload["record_type"] as? String,
              let category = fact.payload["category"] as? String,
              let merchant = fact.payload["merchant"] as? String,
              let amount = FinanceFact.double(from: fact.payload["amount"]),
              let currency = fact.payload["currency"] as? String,
              let date = fact.payload["date"] as? String else {
            return nil
        }
        self.id = fact.id
        self.date = date
        self.month = (fact.payload["month"] as? String) ?? String(date.prefix(7))
        self.recordType = recordType
        self.category = category
        self.merchant = merchant
        self.amount = amount
        self.currency = currency
        self.channel = fact.payload["channel"] as? String
        self.location = fact.payload["location"] as? String
        self.note = fact.payload["note"] as? String
        self.timeOfDay = fact.payload["time_of_day"] as? String
        self.tsMs = fact.tsMs
    }

    var searchItem: ExpenseSearchItem {
        ExpenseSearchItem(
            id: id,
            date: date,
            month: month,
            recordType: recordType,
            category: category,
            merchant: merchant,
            amount: amount,
            currency: currency,
            channel: channel,
            location: location,
            note: note
        )
    }

    private static func double(from value: Any?) -> Double? {
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

private struct ExpenseSearchResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalAmount: Double
    let currency: String
    let recordTypeTotals: [String: Double]
    let items: [ExpenseSearchItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalAmount = "total_amount"
        case currency
        case recordTypeTotals = "record_type_totals"
        case items
    }
}

private struct ExpenseSearchItem: Codable {
    let id: String
    let date: String
    let month: String
    let recordType: String
    let category: String
    let merchant: String
    let amount: Double
    let currency: String
    let channel: String?
    let location: String?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case month
        case recordType = "record_type"
        case category
        case merchant
        case amount
        case currency
        case channel
        case location
        case note
    }
}

private struct ExpenseSummaryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalAmount: Double
    let currency: String
    let groupBy: String
    let groups: [ExpenseGroupSummary]
    let recordTypeTotals: [String: Double]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalAmount = "total_amount"
        case currency
        case groupBy = "group_by"
        case groups
        case recordTypeTotals = "record_type_totals"
    }
}

private struct ExpenseGroupSummary: Codable {
    let key: String
    var count: Int
    var amount: Double

    var rounded: ExpenseGroupSummary {
        ExpenseGroupSummary(
            key: key,
            count: count,
            amount: (amount * 100).rounded() / 100
        )
    }
}
