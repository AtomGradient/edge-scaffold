// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeHalo
import EdgeMesh

enum RPPDemoData {

    static func loadData() -> ([String], [RPPRawTransaction]) {
        if let txns = selectedDomainTransactions(), !txns.isEmpty {
            let domain = ScaffoldSampleDomainRegistry.selectedDomain
            let sentences = txns.map { activitySentence(for: $0, domain: domain) }
            return (sentences, txns)
        }
        let txns = demoTransactions
        let sentences = txns.map { activitySentence(for: $0) }
        return (sentences, txns)
    }


    static func activitySentence(for t: RPPRawTransaction) -> String {
        "The user's activity record: on \(t.weekday) \(t.timeStr), category \(t.category) at \(t.location), amount \(String(format: "%.0f", t.amount))"
    }

    static func activitySentence(
        for t: RPPRawTransaction,
        domain: ScaffoldSampleDomainDescriptor
    ) -> String {
        "The user's \(domain.displayName) record: on \(t.weekday) \(t.timeStr), category \(t.category), entity \(t.location), value \(String(format: "%.0f", t.amount))"
    }

    static func selectedDomainTransactions(limit: Int? = 1_000) -> [RPPRawTransaction]? {
        let domain = ScaffoldSampleDomainRegistry.selectedDomain
        guard let facts = try? Edge.queryFacts(
            namespace: domain.namespace,
            status: .classifiedOnly,
            limit: limit
        ) else {
            return nil
        }
        let txns = facts.compactMap { fact -> RPPRawTransaction? in
            let category = string(from: fact.payload["category"])
                ?? string(from: fact.payload["record_type"])
                ?? string(from: fact.payload["activity"])
                ?? string(from: fact.payload["genre"])
                ?? string(from: fact.payload["project"])
                ?? "general"
            let amount = double(from: fact.payload["amount"])
                ?? double(from: fact.payload["cost"])
                ?? double(from: fact.payload["duration_minutes"])
                ?? double(from: fact.payload["calories"])
                ?? double(from: fact.payload["pages_read"])
                ?? double(from: fact.payload["rating"])
                ?? double(from: fact.payload["value"])
                ?? 1
            let weekday = string(from: fact.payload["weekday"]) ?? "unknown"
            let timeStr = string(from: fact.payload["time_of_day"]) ?? string(from: fact.payload["date"]) ?? "unknown"
            let location = string(from: fact.payload["location"])
                ?? string(from: fact.payload["merchant"])
                ?? string(from: fact.payload["title"])
                ?? string(from: fact.payload["dish_name"])
                ?? string(from: fact.payload["destination"])
                ?? string(from: fact.payload["activity"])
                ?? "unknown"
            return RPPRawTransaction(
                weekday: weekday,
                timeStr: timeStr,
                category: category,
                location: location,
                amount: amount
            )
        }
        return txns.sorted { $0.amount > $1.amount }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let value as String where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return value
        case let value as CustomStringConvertible:
            return value.description
        default:
            return nil
        }
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


    static let demoTransactions: [RPPRawTransaction] = [
        RPPRawTransaction(weekday: "Monday", timeStr: "morning", category: "dining", location: "cafe", amount: 28),
        RPPRawTransaction(weekday: "Tuesday", timeStr: "noon", category: "dining", location: "restaurant", amount: 65),
        RPPRawTransaction(weekday: "Wednesday", timeStr: "evening", category: "dining", location: "fast_food", amount: 35),
        RPPRawTransaction(weekday: "Friday", timeStr: "noon", category: "dining", location: "restaurant", amount: 120),
        RPPRawTransaction(weekday: "Saturday", timeStr: "evening", category: "dining", location: "restaurant", amount: 280),
        RPPRawTransaction(weekday: "Monday", timeStr: "morning", category: "transport", location: "subway", amount: 5),
        RPPRawTransaction(weekday: "Tuesday", timeStr: "morning", category: "transport", location: "bus", amount: 3),
        RPPRawTransaction(weekday: "Wednesday", timeStr: "evening", category: "transport", location: "taxi", amount: 45),
        RPPRawTransaction(weekday: "Thursday", timeStr: "morning", category: "transport", location: "subway", amount: 5),
        RPPRawTransaction(weekday: "Friday", timeStr: "evening", category: "transport", location: "taxi", amount: 60),
        RPPRawTransaction(weekday: "Saturday", timeStr: "afternoon", category: "shopping", location: "mall", amount: 350),
        RPPRawTransaction(weekday: "Sunday", timeStr: "afternoon", category: "shopping", location: "online", amount: 199),
        RPPRawTransaction(weekday: "Wednesday", timeStr: "evening", category: "shopping", location: "supermarket", amount: 86),
        RPPRawTransaction(weekday: "Saturday", timeStr: "morning", category: "shopping", location: "market", amount: 45),
        RPPRawTransaction(weekday: "Friday", timeStr: "evening", category: "entertainment", location: "cinema", amount: 80),
        RPPRawTransaction(weekday: "Saturday", timeStr: "afternoon", category: "entertainment", location: "gym", amount: 0),
        RPPRawTransaction(weekday: "Sunday", timeStr: "morning", category: "entertainment", location: "park", amount: 0),
        RPPRawTransaction(weekday: "Saturday", timeStr: "evening", category: "entertainment", location: "bar", amount: 150),
        RPPRawTransaction(weekday: "Monday", timeStr: "afternoon", category: "utilities", location: "online", amount: 200),
        RPPRawTransaction(weekday: "Thursday", timeStr: "morning", category: "healthcare", location: "pharmacy", amount: 58),
        RPPRawTransaction(weekday: "Wednesday", timeStr: "afternoon", category: "education", location: "bookstore", amount: 120),
        RPPRawTransaction(weekday: "Friday", timeStr: "morning", category: "healthcare", location: "clinic", amount: 300),
        RPPRawTransaction(weekday: "Sunday", timeStr: "afternoon", category: "shopping", location: "electronics", amount: 2999),
        RPPRawTransaction(weekday: "Saturday", timeStr: "noon", category: "dining", location: "fine_dining", amount: 580),
        RPPRawTransaction(weekday: "Thursday", timeStr: "evening", category: "entertainment", location: "concert", amount: 480),
    ]
}


struct ScaffoldPersonaRPPInputSourceRecord: Sendable {
    let stableID: String
    let kind: String?
    let text: String
    let tags: [String]

    init(
        stableID: String,
        kind: String? = nil,
        text: String,
        tags: [String] = []
    ) {
        self.stableID = stableID
        self.kind = kind
        self.text = text
        self.tags = tags
    }
}

enum ScaffoldPersonaRPPInputExporterError: LocalizedError {
    case noRecords

    var errorDescription: String? {
        switch self {
        case .noRecords:
            return "No Persona RPP input records to upload"
        }
    }
}

enum ScaffoldPersonaRPPInputExporter {
    static func records(
        from sourceRecords: [ScaffoldPersonaRPPInputSourceRecord]
    ) throws -> [PersonaRPPInputRecord] {
        let records = sourceRecords.compactMap { source -> PersonaRPPInputRecord? in
            let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordID = source.stableID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !recordID.isEmpty else { return nil }

            let kind = source.kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = source.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return PersonaRPPInputRecord(
                recordID: recordID,
                kind: kind?.isEmpty == false ? kind : nil,
                text: text,
                tags: tags.isEmpty ? nil : tags
            )
        }
        guard !records.isEmpty else { throw ScaffoldPersonaRPPInputExporterError.noRecords }
        return records
    }

    static func payload(
        peerID: String,
        appID: String,
        baseModelID: String,
        sourceKind: PersonaRPPInputSourceKind = .appFacts,
        sourceRecords: [ScaffoldPersonaRPPInputSourceRecord],
        inputNote: String? = nil
    ) throws -> PersonaRPPInputUploadPayload {
        try PersonaRPPInputUploadPayload(
            peerID: peerID,
            appID: appID,
            baseModelID: baseModelID,
            sourceKind: sourceKind,
            records: records(from: sourceRecords),
            inputNote: inputNote
        )
    }

    static func demoSourceRecords(limit: Int = 10_000) -> [ScaffoldPersonaRPPInputSourceRecord] {
        let domain = ScaffoldSampleDomainRegistry.selectedDomain
        if let transactions = RPPDemoData.selectedDomainTransactions(limit: limit),
           !transactions.isEmpty {
            return transactions.enumerated().map { index, txn in
                ScaffoldPersonaRPPInputSourceRecord(
                    stableID: String(format: "scaffold.%@.%03d", domain.id.rawValue, index + 1),
                    kind: "scaffold_\(domain.id.rawValue)_fact_sentence",
                    text: RPPDemoData.activitySentence(for: txn, domain: domain),
                    tags: ["scaffold", "synthetic", domain.id.rawValue, "rpp_input"]
                )
            }
        }
        return Array(RPPDemoData.demoTransactions.prefix(max(0, limit))).enumerated().map { index, txn in
            ScaffoldPersonaRPPInputSourceRecord(
                stableID: String(format: "scaffold.demo.%03d", index + 1),
                kind: "demo_activity_sentence",
                text: RPPDemoData.activitySentence(for: txn),
                tags: ["scaffold", "demo", "rpp_input"]
            )
        }
    }
}
