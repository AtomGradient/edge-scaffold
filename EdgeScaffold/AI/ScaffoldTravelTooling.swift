// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldTravelTooling {
    static let recordsToolName = "query_travel_records"
    static let spendingToolName = "query_travel_spending"

    static let toolNames = [
        recordsToolName,
        spendingToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: recordsToolName,
                description: "Query synthetic travel records by destination, origin, record type, transport mode, tags, note text, companions, or date range. Use for exact itinerary records, latest/recent trips, business travel, hotel, transit, attraction, dining, and evidence examples.",
                argumentsSchema: .jsonSchema(recordsArgumentsSchema),
                resultSchema: .jsonSchema(travelQueryResultSchema),
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
                description: "Aggregate synthetic travel costs by destination, record type, transport mode, hotel, or date range. Use for exact travel spend totals, current/last period amounts, date-range sums, dining while traveling, transit costs, hotel costs, and trip budget summaries.",
                argumentsSchema: .jsonSchema(spendingArgumentsSchema),
                resultSchema: .jsonSchema(travelQueryResultSchema),
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
        let destination = stringValue(arguments["destination"])?.lowercased()
        let origin = stringValue(arguments["origin"])?.lowercased()
        let transportMode = stringValue(arguments["transport_mode"] ?? arguments["transportMode"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let text = stringValue(arguments["text"])?.lowercased()
        let companions = stringValue(arguments["companions"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try travelFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let destination, !(item.destination?.lowercased().contains(destination) ?? false) { return false }
            if let origin, !(item.origin?.lowercased().contains(origin) ?? false) { return false }
            if let transportMode, item.transportMode?.lowercased() != transportMode { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let text, !item.searchText.lowercased().contains(text) { return false }
            if let companions, !(item.companions?.lowercased().contains(companions) ?? false) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(TravelQueryResult(
            namespace: ScaffoldTravelSample.namespace,
            schema: ScaffoldTravelSample.schemaName,
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
        let destination = stringValue(arguments["destination"])?.lowercased()
        let transportMode = stringValue(arguments["transport_mode"] ?? arguments["transportMode"])?.lowercased()
        let hotel = stringValue(arguments["hotel"])?.lowercased()
        let minCost = doubleValue(arguments["min_cost"] ?? arguments["minCost"])
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try travelFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let destination, !(item.destination?.lowercased().contains(destination) ?? false) { return false }
            if let transportMode, item.transportMode?.lowercased() != transportMode { return false }
            if let hotel, !(item.hotel?.lowercased().contains(hotel) ?? false) { return false }
            if let minCost, (item.cost ?? 0) < minCost { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(TravelQueryResult(
            namespace: ScaffoldTravelSample.namespace,
            schema: ScaffoldTravelSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalCost: rounded(filtered.compactMap(\.cost).reduce(0, +)),
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            currency: "CNY",
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func travelFacts() throws -> [TravelFact] {
        try Edge.queryFacts(
            namespace: ScaffoldTravelSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(TravelFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [TravelFact]) -> [TravelGroupSummary] {
        var groups: [String: TravelGroupSummary] = [:]
        for fact in facts {
            let key = fact.recordType
            var current = groups[key] ?? TravelGroupSummary(
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
                if lhs.totalCost == rhs.totalCost { return lhs.key < rhs.key }
                return lhs.totalCost > rhs.totalCost
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
          "enum": ["attraction", "dining_out", "transit", "flight", "hotel", "train"],
          "description": "Optional travel record type filter."
        },
        "destination": {
          "type": "string",
          "description": "Optional destination substring."
        },
        "origin": {
          "type": "string",
          "description": "Optional origin substring."
        },
        "transport_mode": {
          "type": "string",
          "enum": ["flight", "high_speed_rail", "metro", "taxi", "bus", "walk"],
          "description": "Optional transport mode filter."
        },
        "tags": {
          "type": "string",
          "description": "Optional tags substring."
        },
        "text": {
          "type": "string",
          "description": "Optional search text across title, destination, note, tags, hotel, and carrier."
        },
        "companions": {
          "type": "string",
          "description": "Optional companions substring."
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

    private static let spendingArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["attraction", "dining_out", "transit", "flight", "hotel", "train"],
          "description": "Optional travel record type filter."
        },
        "destination": {
          "type": "string",
          "description": "Optional destination substring."
        },
        "transport_mode": {
          "type": "string",
          "enum": ["flight", "high_speed_rail", "metro", "taxi", "bus", "walk"],
          "description": "Optional transport mode filter."
        },
        "hotel": {
          "type": "string",
          "description": "Optional hotel substring."
        },
        "min_cost": {
          "type": "number",
          "description": "Optional minimum cost filter."
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

    private static let travelQueryResultSchema = """
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

private struct TravelFact {
    let date: String
    let recordType: String
    let title: String
    let origin: String?
    let destination: String?
    let transportMode: String?
    let carrier: String?
    let cost: Double?
    let currency: String?
    let durationMinutes: Double?
    let hotel: String?
    let rating: Double?
    let tags: String?
    let note: String?
    let companions: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldTravelSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let title = fact.payload["title"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.title = title
        self.origin = fact.payload["origin"] as? String
        self.destination = fact.payload["destination"] as? String
        self.transportMode = fact.payload["transport_mode"] as? String
        self.carrier = fact.payload["carrier"] as? String
        self.cost = fact.payload["cost"] as? Double
        self.currency = fact.payload["currency"] as? String
        self.durationMinutes = fact.payload["duration_minutes"] as? Double
        self.hotel = fact.payload["hotel"] as? String
        self.rating = fact.payload["rating"] as? Double
        self.tags = fact.payload["tags"] as? String
        self.note = fact.payload["note"] as? String
        self.companions = fact.payload["companions"] as? String
        self.tsMs = fact.tsMs
    }

    var searchText: String {
        [
            title,
            origin,
            destination,
            transportMode,
            carrier,
            hotel,
            tags,
            note,
            companions,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var item: TravelRecordItem {
        TravelRecordItem(
            date: date,
            recordType: recordType,
            title: title,
            origin: origin,
            destination: destination,
            transportMode: transportMode,
            carrier: carrier,
            cost: cost,
            currency: currency,
            durationMinutes: durationMinutes,
            hotel: hotel,
            rating: rating,
            tags: tags,
            note: note,
            companions: companions
        )
    }
}

private struct TravelQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalCost: Double
    let totalDurationMinutes: Double
    let currency: String
    let groups: [TravelGroupSummary]
    let items: [TravelRecordItem]

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

private struct TravelRecordItem: Codable {
    let date: String
    let recordType: String
    let title: String
    let origin: String?
    let destination: String?
    let transportMode: String?
    let carrier: String?
    let cost: Double?
    let currency: String?
    let durationMinutes: Double?
    let hotel: String?
    let rating: Double?
    let tags: String?
    let note: String?
    let companions: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case recordType = "record_type"
        case title
        case origin
        case destination
        case transportMode = "transport_mode"
        case carrier
        case cost
        case currency
        case durationMinutes = "duration_minutes"
        case hotel
        case rating
        case tags
        case note
        case companions
    }
}

private struct TravelGroupSummary: Codable {
    let key: String
    var count: Int
    var totalCost: Double
    var totalDurationMinutes: Double

    var rounded: TravelGroupSummary {
        TravelGroupSummary(
            key: key,
            count: count,
            totalCost: ScaffoldTravelTooling.rounded(totalCost),
            totalDurationMinutes: ScaffoldTravelTooling.rounded(totalDurationMinutes)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalCost = "total_cost"
        case totalDurationMinutes = "total_duration_minutes"
    }
}
