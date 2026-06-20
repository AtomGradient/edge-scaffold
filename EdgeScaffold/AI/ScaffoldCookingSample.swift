// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData

enum ScaffoldCookingSample {
    static let namespace = "scaffold.cooking"
    static let schemaName = "scaffold.cooking.record"
    static let resourceName = "scaffold_cooking_sample"

    static let recordTypes = ["grocery", "meal_plan", "cooking", "baking", "recipe_saved"]
    static let timeOfDayValues = ["morning", "midday", "afternoon", "evening", "night"]
    static let cuisines = [
        "chinese_home", "chinese_regional", "japanese", "korean",
        "southeast_asian", "western", "baking", "other"
    ]
    static let difficulties = ["easy", "medium", "hard"]

    static func registerSchema() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "record_type", type: .categorical(recordTypes), required: true),
                FieldDef(name: "date", type: .text, required: true),
                FieldDef(name: "weekday", type: .text, required: false),
                FieldDef(name: "time_of_day", type: .categorical(timeOfDayValues), required: false),
                FieldDef(name: "dish_name", type: .entity, required: true),
                FieldDef(name: "cuisine", type: .categorical(cuisines), required: false),
                FieldDef(name: "difficulty", type: .categorical(difficulties), required: false),
                FieldDef(name: "duration_minutes", type: .numeric, required: false),
                FieldDef(name: "servings", type: .numeric, required: false),
                FieldDef(name: "ingredients", type: .text, required: false),
                FieldDef(name: "cost", type: .numeric, required: false),
                FieldDef(name: "rating", type: .numeric, required: false),
                FieldDef(name: "tags", type: .text, required: false),
                FieldDef(name: "note", type: .text, required: false),
                FieldDef(name: "source", type: .entity, required: false),
                FieldDef(name: "synthetic", type: .categorical(["true"]), required: true),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: "date",
                primaryValue: "cost",
                primaryEntity: "dish_name"
            )
        ))
    }

    static func loadRecords() throws -> [ScaffoldCookingSampleRecord] {
        let urls = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "SampleData"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "json"),
        ].compactMap { $0 }

        guard let url = urls.first else {
            throw ScaffoldCookingSampleError.resourceMissing(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScaffoldCookingSampleRecord].self, from: data)
    }

    @discardableResult
    static func seedRawFacts(limit: Int? = nil) throws -> SeedResult {
        registerSchema()
        let records = Array(try loadRecords().prefix(limit ?? Int.max))
        var written = 0
        for record in records {
            _ = try Edge.recordRaw(
                fact: RawFact(
                    namespace: namespace,
                    rawPayload: record.rawPayload,
                    candidateSchemas: [schemaName],
                    sensitivity: .meshOk
                ),
                customFactId: rawFactID(for: record.id)
            )
            written += 1
        }
        return try stats(written: written)
    }

    @discardableResult
    static func seedClassifiedFacts(limit: Int? = nil) throws -> SeedResult {
        registerSchema()
        let records = Array(try loadRecords().prefix(limit ?? Int.max))
        let existingIDs = Set(try Edge.queryFacts(
            namespace: namespace,
            status: .all,
            limit: max(records.count * 2, 1_000)
        ).map(\.id))

        var written = 0
        for record in records {
            let factID = classifiedFactID(for: record.id)
            guard !existingIDs.contains(factID) else { continue }
            try Edge.record(fact: Fact(
                id: factID,
                namespace: namespace,
                schema: schemaName,
                payload: record.classifiedPayload,
                sensitivity: .meshOk,
                tsMs: record.tsMs
            ))
            written += 1
        }
        return try stats(written: written)
    }

    static func stats(written: Int = 0) throws -> SeedResult {
        SeedResult(
            sampleRecords: (try? loadRecords().count) ?? 0,
            writtenThisRun: written,
            rawUnclassified: try Edge.countFacts(namespace: namespace, status: .rawUnclassified),
            classified: try Edge.countFacts(namespace: namespace, status: .classifiedOnly),
            total: try Edge.countFacts(namespace: namespace, status: .all)
        )
    }

    static func rawFactID(for sampleID: String) -> String {
        "scaffold.cooking.raw.\(sampleID)"
    }

    static func classifiedFactID(for sampleID: String) -> String {
        "scaffold.cooking.classified.\(sampleID)"
    }
}

struct ScaffoldCookingSampleRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let weekday: String
    let timeOfDay: String?
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
    let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case weekday
        case timeOfDay = "time_of_day"
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
        case synthetic
    }

    var summary: String {
        var parts = [
            date,
            timeOfDay ?? "unknown_time",
            recordType,
            dishName,
        ]
        if let cuisine {
            parts.append("cuisine=\(cuisine)")
        }
        if let difficulty {
            parts.append("difficulty=\(difficulty)")
        }
        if let durationMinutes {
            parts.append("duration_minutes=\(durationMinutes)")
        }
        if let servings {
            parts.append("servings=\(servings)")
        }
        if let ingredients {
            parts.append("ingredients=\(ingredients)")
        }
        if let cost {
            parts.append("cost=\(cost)")
        }
        if let rating {
            parts.append("rating=\(rating)")
        }
        if let tags {
            parts.append("tags=\(tags)")
        }
        if let note {
            parts.append("note=\(note)")
        }
        if let source {
            parts.append("source=\(source)")
        }
        return parts.joined(separator: ", ")
    }

    var rawPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": summary,
            "sample_source": "edge_scaffold_synthetic_cooking_sample",
            "date": date,
            "weekday": weekday,
            "record_type": recordType,
            "dish_name": dishName,
            "synthetic": true,
        ]
        payload["time_of_day"] = timeOfDay
        payload["cuisine"] = cuisine
        payload["difficulty"] = difficulty
        payload["duration_minutes"] = durationMinutes
        payload["servings"] = servings
        payload["ingredients"] = ingredients
        payload["cost"] = cost
        payload["rating"] = rating
        payload["tags"] = tags
        payload["note"] = note
        payload["source"] = source
        return payload.compactMapValues { $0 }
    }

    var classifiedPayload: [String: Any] {
        rawPayload
    }

    var tsMs: Int64 {
        guard let dateValue = Self.dateFormatter.date(from: date) else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        let offsetHours: Double
        switch timeOfDay {
        case "morning": offsetHours = 8
        case "midday": offsetHours = 12
        case "afternoon": offsetHours = 15
        case "evening": offsetHours = 19
        case "night": offsetHours = 22
        default: offsetHours = 12
        }
        let adjusted = dateValue.addingTimeInterval(offsetHours * 3600)
        return Int64(adjusted.timeIntervalSince1970 * 1000)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension ScaffoldCookingSample {
    struct SeedResult: Equatable {
        let sampleRecords: Int
        let writtenThisRun: Int
        let rawUnclassified: Int
        let classified: Int
        let total: Int
    }
}

enum ScaffoldCookingSampleError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing bundled sample data resource: \(name).json"
        }
    }
}
