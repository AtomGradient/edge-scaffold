// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData

enum ScaffoldFinanceSample {
    static let namespace = "scaffold.finance"
    static let schemaName = "scaffold.finance.transaction"
    static let resourceName = "scaffold_finance_sample"

    static let categories = [
        "coffee", "dining", "transport", "groceries", "shopping",
        "entertainment", "education", "medical", "subscription",
        "utilities", "rent", "insurance", "salary", "freelance",
        "transfer_in", "transfer_out", "refund", "gift", "other"
    ]

    static let recordTypes = ["expense", "income", "transfer", "refund"]
    static let channels = [
        "mobile_pay", "bank_transfer", "credit_card", "auto_debit",
        "debit_card", "cash"
    ]

    static func registerSchema() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "record_type", type: .categorical(recordTypes), required: true),
                FieldDef(name: "category", type: .categorical(categories), required: true),
                FieldDef(name: "amount", type: .numeric, required: true),
                FieldDef(name: "currency", type: .categorical(["CNY"]), required: true),
                FieldDef(name: "merchant", type: .entity, required: true),
                FieldDef(name: "date", type: .text, required: true),
                FieldDef(name: "month", type: .text, required: true),
                FieldDef(name: "weekday", type: .text, required: false),
                FieldDef(name: "time_of_day", type: .categorical([
                    "morning", "midday", "afternoon", "evening", "night"
                ]), required: false),
                FieldDef(name: "channel", type: .categorical(channels), required: false),
                FieldDef(name: "location", type: .entity, required: false),
                FieldDef(name: "note", type: .text, required: false),
                FieldDef(name: "synthetic", type: .categorical(["true"]), required: true),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: "date",
                primaryValue: "amount",
                primaryEntity: "merchant"
            )
        ))
    }

    static func loadRecords() throws -> [ScaffoldFinanceSampleRecord] {
        let urls = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "SampleData"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "json"),
        ].compactMap { $0 }

        guard let url = urls.first else {
            throw ScaffoldFinanceSampleError.resourceMissing(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScaffoldFinanceSampleRecord].self, from: data)
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
            limit: max(records.count * 2, 500)
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

    static func demoRecords(limit: Int = 8) -> [ScaffoldFinanceSampleRecord] {
        (try? Array(loadRecords().prefix(limit))) ?? []
    }

    static func rawFactID(for sampleID: String) -> String {
        "scaffold.finance.raw.\(sampleID)"
    }

    static func classifiedFactID(for sampleID: String) -> String {
        "scaffold.finance.classified.\(sampleID)"
    }
}

struct ScaffoldFinanceSampleRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let weekday: String
    let timeOfDay: String
    let amount: Double
    let currency: String
    let merchant: String
    let categoryHint: String
    let location: String
    let channel: String
    let note: String?
    let synthetic: Bool
    let recordType: String

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case weekday
        case timeOfDay = "time_of_day"
        case amount
        case currency
        case merchant
        case categoryHint = "category_hint"
        case location
        case channel
        case note
        case synthetic
        case recordType = "record_type"
    }

    var month: String {
        String(date.prefix(7))
    }

    var summary: String {
        let noteSuffix = note.map { ", note=\($0)" } ?? ""
        return "\(date) \(timeOfDay), \(recordType), \(merchant), \(amount) \(currency), channel=\(channel), location=\(location)\(noteSuffix)"
    }

    var rawPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": summary,
            "source": "edge_scaffold_synthetic_finance_sample",
            "date": date,
            "weekday": weekday,
            "time_of_day": timeOfDay,
            "amount": amount,
            "currency": currency,
            "merchant": merchant,
            "location": location,
            "channel": channel,
            "record_type": recordType,
            "synthetic": true,
        ]
        if let note {
            payload["note"] = note
        }
        return payload
    }

    var classifiedPayload: [String: Any] {
        var payload = rawPayload
        payload["category"] = categoryHint
        payload["month"] = month
        return payload
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

extension ScaffoldFinanceSample {
    struct SeedResult: Equatable {
        let sampleRecords: Int
        let writtenThisRun: Int
        let rawUnclassified: Int
        let classified: Int
        let total: Int
    }
}

enum ScaffoldFinanceSampleError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing bundled sample data resource: \(name).json"
        }
    }
}
