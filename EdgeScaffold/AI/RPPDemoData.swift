// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeHalo
import EdgeMesh

/// One sample domain's explicit RPP input contract: which payload fields
/// become which record roles, which fields the model must treat as not
/// provided, the wording, and the per-record weighting. The template declares
/// this per domain; Edge Halo itself assumes no scenario, no field name and no
/// weighting formula.
struct ScaffoldRPPDomainContract {
    let schema: RPPRecordSchema
    let groupPayloadKey: String?
    let sourcePayloadKey: String?
    let valuePayloadKey: String?
    let profileContext: RPPProfileContext
    /// Provenance of `log1p(max(value, 0))` when a domain opts into value
    /// weighting; nil keeps the SDK default of uniform weights.
    let log1pWeightProvenance: RPPSampleWeightProvenance?

    func sampleWeighting(for records: [RPPRecord]) -> RPPSampleWeighting {
        guard let log1pWeightProvenance else { return .uniform }
        return .explicit(
            records.map { record in
                // A record without a value cannot be weighted by it; the
                // contract keeps it in the decomposition with zero weight
                // rather than inventing a value.
                guard let value = record.value else { return 0 }
                return Float(log1p(max(value, 0)))
            },
            provenance: log1pWeightProvenance
        )
    }
}

enum ScaffoldRPPContracts {
    /// Context labels every sample domain carries, in contract order.
    static let contextPayloadKeys = ["weekday", "time_of_day"]

    static func contract(for domain: ScaffoldSampleDomainDescriptor) -> ScaffoldRPPDomainContract {
        switch domain.id {
        case .finance:
            // The consumption sample keeps the first scenario's instantiation:
            // finance wording and the log1p(amount) weighting, declared here.
            return make(
                domain,
                group: "category", source: "merchant",
                value: ("amount", "金额", "元"),
                notProvided: ["channel", "note"],
                profileContext: .finance,
                log1pWeightSourceField: "amount"
            )
        case .health:
            // The schema's primaryValue `value` carries a per-record `unit`
            // (mixed units), so it cannot be one numeric role; duration is
            // the single-unit value this contract declares.
            return make(domain, group: "activity", source: "location",
                        value: ("duration_minutes", "时长", "分钟"),
                        notProvided: ["calories", "value", "unit"])
        case .reading:
            return make(domain, group: "category", source: "title",
                        value: ("duration_minutes", "时长", "分钟"),
                        notProvided: ["pages_read", "rating"])
        case .journal:
            // Journal entries carry no numeric field: a value-less contract.
            return make(domain, group: "record_type", source: "title",
                        value: nil, notProvided: [])
        case .travel:
            return make(domain, group: "record_type", source: "destination",
                        value: ("cost", "费用", ""),
                        notProvided: ["duration_minutes", "rating"])
        case .cooking:
            return make(domain, group: "record_type", source: "dish_name",
                        value: ("cost", "费用", ""),
                        notProvided: ["duration_minutes", "rating"])
        case .music:
            return make(domain, group: "genre", source: "title",
                        value: ("duration_minutes", "时长", "分钟"),
                        notProvided: ["rating"])
        case .work:
            return make(domain, group: "category", source: "title",
                        value: ("duration_minutes", "时长", "分钟"),
                        notProvided: ["project"])
        }
    }

    private static func make(
        _ domain: ScaffoldSampleDomainDescriptor,
        group: String?,
        source: String?,
        value: (key: String, noun: String, unit: String)?,
        notProvided: [String],
        profileContext: RPPProfileContext? = nil,
        log1pWeightSourceField: String? = nil
    ) -> ScaffoldRPPDomainContract {
        let schema = RPPRecordSchema(
            schemaID: "scaffold.\(domain.id.rawValue).v1",
            contextKeys: contextPayloadKeys,
            groupKey: group,
            sourceKey: source,
            valueKey: value?.key,
            contextBucketIndex: 0,
            fieldsNotProvided: notProvided
        )
        let context = profileContext ?? RPPProfileContext(
            domainID: domain.id.rawValue,
            domainDisplayName: domain.displayName,
            recordNoun: "记录",
            valueNoun: value?.noun ?? "记录值",
            valueUnit: value?.unit ?? "",
            analystRole: "熟悉该领域的个人分析助手"
        )
        return ScaffoldRPPDomainContract(
            schema: schema,
            groupPayloadKey: group,
            sourcePayloadKey: source,
            valuePayloadKey: value?.key,
            profileContext: context,
            log1pWeightProvenance: log1pWeightSourceField.map {
                RPPSampleWeightProvenance(
                    formulaID: "log1p_clamped_nonneg",
                    formulaVersion: "1",
                    sourceField: $0
                )
            }
        )
    }
}

enum RPPDemoData {

    struct Dataset {
        let sentences: [String]
        let records: [RPPRecord]
        let contract: ScaffoldRPPDomainContract
    }

    static func loadData() -> Dataset {
        let domain = ScaffoldSampleDomainRegistry.selectedDomain
        if let loaded = selectedDomainRecords(), !loaded.records.isEmpty {
            let sentences = loaded.records.map {
                activitySentence(for: $0, domain: domain, contract: loaded.contract)
            }
            return Dataset(sentences: sentences, records: loaded.records, contract: loaded.contract)
        }
        let contract = ScaffoldRPPContracts.contract(for: ScaffoldSampleDomainRegistry.descriptor(forRawValue: ScaffoldSampleDomainID.finance.rawValue))
        let records = demoRecords
        let sentences = records.map { activitySentence(for: $0, contract: contract) }
        return Dataset(sentences: sentences, records: records, contract: contract)
    }

    /// Built-in consumption demo sentence (finance contract only).
    static func activitySentence(for record: RPPRecord, contract: ScaffoldRPPDomainContract) -> String {
        var parts = ["The user's activity record: on \(record.context.joined(separator: " "))"]
        if let group = record.group { parts.append("category \(group)") }
        if let source = record.source { parts.append("at \(source)") }
        if let value = record.value { parts.append("amount \(String(format: "%.0f", value))") }
        return parts.joined(separator: ", ")
    }

    /// Sentence for a sample-domain record. Only fields the record carries
    /// appear, under the field names the domain contract declares.
    static func activitySentence(
        for record: RPPRecord,
        domain: ScaffoldSampleDomainDescriptor,
        contract: ScaffoldRPPDomainContract
    ) -> String {
        let when = record.context.filter { !$0.isEmpty }.joined(separator: " ")
        var parts = ["The user's \(domain.displayName) record: on \(when.isEmpty ? "an unknown day" : when)"]
        if let group = record.group, let key = contract.schema.groupKey {
            parts.append("\(key) \(group)")
        }
        if let source = record.source, let key = contract.schema.sourceKey {
            parts.append("\(key) \(source)")
        }
        if let value = record.value, let key = contract.schema.valueKey {
            parts.append("\(key) \(String(format: "%.0f", value))")
        }
        return parts.joined(separator: ", ")
    }

    /// Records of the selected sample domain on its declared contract. A
    /// missing payload field stays missing (nil role); nothing is padded.
    static func selectedDomainRecords(limit: Int? = 1_000)
        -> (records: [RPPRecord], contract: ScaffoldRPPDomainContract)?
    {
        let domain = ScaffoldSampleDomainRegistry.selectedDomain
        let contract = ScaffoldRPPContracts.contract(for: domain)
        guard let facts = try? Edge.queryFacts(
            namespace: domain.namespace,
            status: .classifiedOnly,
            limit: limit
        ) else {
            return nil
        }
        let records = facts.map { record(from: $0.payload, contract: contract) }
        // Deterministic order: valued records by value descending, ties and
        // value-less records in fact order.
        let ordered = records.enumerated().sorted { a, b in
            switch (a.element.value, b.element.value) {
            case let (x?, y?):
                return x != y ? x > y : a.offset < b.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.offset < b.offset
            }
        }.map(\.element)
        return (ordered, contract)
    }

    static func record(from payload: [String: Any], contract: ScaffoldRPPDomainContract) -> RPPRecord {
        RPPRecord(
            context: ScaffoldRPPContracts.contextPayloadKeys.map { string(from: payload[$0]) ?? "" },
            group: contract.groupPayloadKey.flatMap { string(from: payload[$0]) },
            source: contract.sourcePayloadKey.flatMap { string(from: payload[$0]) },
            value: contract.valuePayloadKey.flatMap { double(from: payload[$0]) }
        )
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

    private static func demo(_ weekday: String, _ time: String, _ category: String, _ place: String, _ amount: Double) -> RPPRecord {
        RPPRecord(context: [weekday, time], group: category, source: place, value: amount)
    }

    /// Built-in consumption demo used when the selected domain has no facts.
    static let demoRecords: [RPPRecord] = [
        demo("Monday", "morning", "dining", "cafe", 28),
        demo("Tuesday", "noon", "dining", "restaurant", 65),
        demo("Wednesday", "evening", "dining", "fast_food", 35),
        demo("Friday", "noon", "dining", "restaurant", 120),
        demo("Saturday", "evening", "dining", "restaurant", 280),
        demo("Monday", "morning", "transport", "subway", 5),
        demo("Tuesday", "morning", "transport", "bus", 3),
        demo("Wednesday", "evening", "transport", "taxi", 45),
        demo("Thursday", "morning", "transport", "subway", 5),
        demo("Friday", "evening", "transport", "taxi", 60),
        demo("Saturday", "afternoon", "shopping", "mall", 350),
        demo("Sunday", "afternoon", "shopping", "online", 199),
        demo("Wednesday", "evening", "shopping", "supermarket", 86),
        demo("Saturday", "morning", "shopping", "market", 45),
        demo("Friday", "evening", "entertainment", "cinema", 80),
        demo("Saturday", "afternoon", "entertainment", "gym", 0),
        demo("Sunday", "morning", "entertainment", "park", 0),
        demo("Saturday", "evening", "entertainment", "bar", 150),
        demo("Monday", "afternoon", "utilities", "online", 200),
        demo("Thursday", "morning", "healthcare", "pharmacy", 58),
        demo("Wednesday", "afternoon", "education", "bookstore", 120),
        demo("Friday", "morning", "healthcare", "clinic", 300),
        demo("Sunday", "afternoon", "shopping", "electronics", 2999),
        demo("Saturday", "noon", "dining", "fine_dining", 580),
        demo("Thursday", "evening", "entertainment", "concert", 480),
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
        if let loaded = RPPDemoData.selectedDomainRecords(limit: limit),
           !loaded.records.isEmpty {
            return loaded.records.enumerated().map { index, record in
                ScaffoldPersonaRPPInputSourceRecord(
                    stableID: String(format: "scaffold.%@.%03d", domain.id.rawValue, index + 1),
                    kind: "scaffold_\(domain.id.rawValue)_fact_sentence",
                    text: RPPDemoData.activitySentence(for: record, domain: domain, contract: loaded.contract),
                    tags: ["scaffold", "synthetic", domain.id.rawValue, "rpp_input"]
                )
            }
        }
        let contract = ScaffoldRPPContracts.contract(for: ScaffoldSampleDomainRegistry.descriptor(forRawValue: ScaffoldSampleDomainID.finance.rawValue))
        return Array(RPPDemoData.demoRecords.prefix(max(0, limit))).enumerated().map { index, record in
            ScaffoldPersonaRPPInputSourceRecord(
                stableID: String(format: "scaffold.demo.%03d", index + 1),
                kind: "demo_activity_sentence",
                text: RPPDemoData.activitySentence(for: record, contract: contract),
                tags: ["scaffold", "demo", "rpp_input"]
            )
        }
    }
}
