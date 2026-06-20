// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData

enum ScaffoldJournalSample {
    static let namespace = "scaffold.journal"
    static let schemaName = "scaffold.journal.entry"
    static let resourceName = "scaffold_journal_sample"

    static let recordTypes = ["journal", "task", "idea", "event", "reminder"]
    static let timeOfDayValues = ["morning", "midday", "afternoon", "evening", "night"]
    static let moods = ["happy", "calm", "focused", "anxious", "tired", "excited", "frustrated", "grateful"]
    static let energyValues = ["high", "medium", "low"]
    static let priorities = ["high", "medium", "low"]
    static let statuses = ["pending", "done", "cancelled"]

    static func registerSchema() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "record_type", type: .categorical(recordTypes), required: true),
                FieldDef(name: "date", type: .text, required: true),
                FieldDef(name: "weekday", type: .text, required: false),
                FieldDef(name: "time_of_day", type: .categorical(timeOfDayValues), required: false),
                FieldDef(name: "title", type: .text, required: true),
                FieldDef(name: "body", type: .text, required: false),
                FieldDef(name: "mood", type: .categorical(moods), required: false),
                FieldDef(name: "energy", type: .categorical(energyValues), required: false),
                FieldDef(name: "tags", type: .text, required: false),
                FieldDef(name: "priority", type: .categorical(priorities), required: false),
                FieldDef(name: "status", type: .categorical(statuses), required: false),
                FieldDef(name: "location", type: .entity, required: false),
                FieldDef(name: "people", type: .text, required: false),
                FieldDef(name: "synthetic", type: .categorical(["true"]), required: true),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: "date",
                primaryValue: nil,
                primaryEntity: "title"
            )
        ))
    }

    static func loadRecords() throws -> [ScaffoldJournalSampleRecord] {
        let urls = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "SampleData"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "json"),
        ].compactMap { $0 }

        guard let url = urls.first else {
            throw ScaffoldJournalSampleError.resourceMissing(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScaffoldJournalSampleRecord].self, from: data)
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
        "scaffold.journal.raw.\(sampleID)"
    }

    static func classifiedFactID(for sampleID: String) -> String {
        "scaffold.journal.classified.\(sampleID)"
    }
}

struct ScaffoldJournalSampleRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let weekday: String
    let timeOfDay: String?
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
    let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case weekday
        case timeOfDay = "time_of_day"
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
        case synthetic
    }

    var summary: String {
        var parts = [
            date,
            timeOfDay ?? "unknown_time",
            recordType,
            title,
        ]
        if let mood {
            parts.append("mood=\(mood)")
        }
        if let energy {
            parts.append("energy=\(energy)")
        }
        if let priority {
            parts.append("priority=\(priority)")
        }
        if let status {
            parts.append("status=\(status)")
        }
        if let location {
            parts.append("location=\(location)")
        }
        if let people {
            parts.append("people=\(people)")
        }
        if let tags {
            parts.append("tags=\(tags)")
        }
        if let body {
            parts.append("body=\(body)")
        }
        return parts.joined(separator: ", ")
    }

    var rawPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": summary,
            "source": "edge_scaffold_synthetic_journal_sample",
            "date": date,
            "weekday": weekday,
            "record_type": recordType,
            "title": title,
            "synthetic": true,
        ]
        payload["time_of_day"] = timeOfDay
        payload["body"] = body
        payload["mood"] = mood
        payload["energy"] = energy
        payload["tags"] = tags
        payload["priority"] = priority
        payload["status"] = status
        payload["location"] = location
        payload["people"] = people
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

extension ScaffoldJournalSample {
    struct SeedResult: Equatable {
        let sampleRecords: Int
        let writtenThisRun: Int
        let rawUnclassified: Int
        let classified: Int
        let total: Int
    }
}

enum ScaffoldJournalSampleError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing bundled sample data resource: \(name).json"
        }
    }
}
