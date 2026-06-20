// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData

enum ScaffoldWorkSample {
    static let namespace = "scaffold.work"
    static let schemaName = "scaffold.work.record"
    static let resourceName = "scaffold_work_sample"

    static let recordTypes = [
        "meeting", "review", "standup", "code_commit",
        "one_on_one", "retrospective", "learning", "milestone"
    ]
    static let timeOfDayValues = ["morning", "midday", "afternoon", "evening"]
    static let categories = ["engineering", "infrastructure", "management", "product", "research"]
    static let statuses = ["blocked", "cancelled", "done", "in_progress"]
    static let priorities = ["high", "medium", "low"]

    static func registerSchema() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "record_type", type: .categorical(recordTypes), required: true),
                FieldDef(name: "date", type: .text, required: true),
                FieldDef(name: "weekday", type: .text, required: false),
                FieldDef(name: "time_of_day", type: .categorical(timeOfDayValues), required: false),
                FieldDef(name: "title", type: .entity, required: true),
                FieldDef(name: "project", type: .entity, required: false),
                FieldDef(name: "category", type: .categorical(categories), required: false),
                FieldDef(name: "duration_minutes", type: .numeric, required: false),
                FieldDef(name: "participants", type: .text, required: false),
                FieldDef(name: "status", type: .categorical(statuses), required: false),
                FieldDef(name: "priority", type: .categorical(priorities), required: false),
                FieldDef(name: "tags", type: .text, required: false),
                FieldDef(name: "outcome", type: .text, required: false),
                FieldDef(name: "note", type: .text, required: false),
                FieldDef(name: "blockers", type: .text, required: false),
                FieldDef(name: "synthetic", type: .categorical(["true"]), required: true),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: "date",
                primaryValue: "duration_minutes",
                primaryEntity: "title"
            )
        ))
    }

    static func loadRecords() throws -> [ScaffoldWorkSampleRecord] {
        let urls = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "SampleData"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "json"),
        ].compactMap { $0 }

        guard let url = urls.first else {
            throw ScaffoldWorkSampleError.resourceMissing(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScaffoldWorkSampleRecord].self, from: data)
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
        "scaffold.work.raw.\(sampleID)"
    }

    static func classifiedFactID(for sampleID: String) -> String {
        "scaffold.work.classified.\(sampleID)"
    }
}

struct ScaffoldWorkSampleRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let weekday: String
    let timeOfDay: String?
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
    let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case weekday
        case timeOfDay = "time_of_day"
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
        case synthetic
    }

    var summary: String {
        var parts = [
            date,
            timeOfDay ?? "unknown_time",
            recordType,
            title,
        ]
        if let project {
            parts.append("project=\(project)")
        }
        if let category {
            parts.append("category=\(category)")
        }
        if let durationMinutes {
            parts.append("duration_minutes=\(durationMinutes)")
        }
        if let participants {
            parts.append("participants=\(participants)")
        }
        if let status {
            parts.append("status=\(status)")
        }
        if let priority {
            parts.append("priority=\(priority)")
        }
        if let tags {
            parts.append("tags=\(tags)")
        }
        if let outcome {
            parts.append("outcome=\(outcome)")
        }
        if let note {
            parts.append("note=\(note)")
        }
        if let blockers {
            parts.append("blockers=\(blockers)")
        }
        return parts.joined(separator: ", ")
    }

    var rawPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": summary,
            "sample_source": "edge_scaffold_synthetic_work_sample",
            "date": date,
            "weekday": weekday,
            "record_type": recordType,
            "title": title,
            "synthetic": true,
        ]
        payload["time_of_day"] = timeOfDay
        payload["project"] = project
        payload["category"] = category
        payload["duration_minutes"] = durationMinutes
        payload["participants"] = participants
        payload["status"] = status
        payload["priority"] = priority
        payload["tags"] = tags
        payload["outcome"] = outcome
        payload["note"] = note
        payload["blockers"] = blockers
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
        case "morning": offsetHours = 9
        case "midday": offsetHours = 12
        case "afternoon": offsetHours = 15
        case "evening": offsetHours = 19
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

extension ScaffoldWorkSample {
    struct SeedResult: Equatable {
        let sampleRecords: Int
        let writtenThisRun: Int
        let rawUnclassified: Int
        let classified: Int
        let total: Int
    }
}

enum ScaffoldWorkSampleError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing bundled sample data resource: \(name).json"
        }
    }
}
