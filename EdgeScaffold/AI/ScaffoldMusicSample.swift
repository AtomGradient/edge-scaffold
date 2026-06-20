// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData

enum ScaffoldMusicSample {
    static let namespace = "scaffold.music"
    static let schemaName = "scaffold.music.record"
    static let resourceName = "scaffold_music_sample"

    static let recordTypes = ["music", "movie", "video", "podcast_listen", "tv_series"]
    static let timeOfDayValues = ["morning", "midday", "afternoon", "evening", "night"]
    static let genres = [
        "pop", "rock", "rap", "hip_hop", "r_and_b", "folk", "jazz", "classical",
        "electronic", "indie", "ost", "action", "animation", "comedy", "documentary",
        "drama", "romance", "sci_fi", "tech", "thriller", "other"
    ]
    static let moodTags = ["chill", "energetic", "focused", "happy", "intense", "melancholy", "nostalgic"]

    static func registerSchema() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "record_type", type: .categorical(recordTypes), required: true),
                FieldDef(name: "date", type: .text, required: true),
                FieldDef(name: "weekday", type: .text, required: false),
                FieldDef(name: "time_of_day", type: .categorical(timeOfDayValues), required: false),
                FieldDef(name: "title", type: .entity, required: true),
                FieldDef(name: "artist", type: .entity, required: false),
                FieldDef(name: "genre", type: .categorical(genres), required: false),
                FieldDef(name: "duration_minutes", type: .numeric, required: false),
                FieldDef(name: "platform", type: .entity, required: false),
                FieldDef(name: "rating", type: .numeric, required: false),
                FieldDef(name: "mood_tag", type: .categorical(moodTags), required: false),
                FieldDef(name: "tags", type: .text, required: false),
                FieldDef(name: "note", type: .text, required: false),
                FieldDef(name: "series_name", type: .entity, required: false),
                FieldDef(name: "episode", type: .text, required: false),
                FieldDef(name: "season", type: .text, required: false),
                FieldDef(name: "synthetic", type: .categorical(["true"]), required: true),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: "date",
                primaryValue: "duration_minutes",
                primaryEntity: "title"
            )
        ))
    }

    static func loadRecords() throws -> [ScaffoldMusicSampleRecord] {
        let urls = [
            Bundle.main.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: "SampleData"
            ),
            Bundle.main.url(forResource: resourceName, withExtension: "json"),
        ].compactMap { $0 }

        guard let url = urls.first else {
            throw ScaffoldMusicSampleError.resourceMissing(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ScaffoldMusicSampleRecord].self, from: data)
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
        "scaffold.music.raw.\(sampleID)"
    }

    static func classifiedFactID(for sampleID: String) -> String {
        "scaffold.music.classified.\(sampleID)"
    }
}

struct ScaffoldMusicSampleRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let weekday: String
    let timeOfDay: String?
    let recordType: String
    let title: String
    let artist: String?
    let genre: String?
    let durationMinutes: Double?
    let platform: String?
    let rating: Double?
    let moodTag: String?
    let tags: String?
    let note: String?
    let seriesName: String?
    let episode: ScaffoldLossyString?
    let season: ScaffoldLossyString?
    let synthetic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case weekday
        case timeOfDay = "time_of_day"
        case recordType = "record_type"
        case title
        case artist
        case genre
        case durationMinutes = "duration_minutes"
        case platform
        case rating
        case moodTag = "mood_tag"
        case tags
        case note
        case seriesName = "series_name"
        case episode
        case season
        case synthetic
    }

    var summary: String {
        var parts = [
            date,
            timeOfDay ?? "unknown_time",
            recordType,
            title,
        ]
        if let artist {
            parts.append("artist=\(artist)")
        }
        if let genre {
            parts.append("genre=\(genre)")
        }
        if let durationMinutes {
            parts.append("duration_minutes=\(durationMinutes)")
        }
        if let platform {
            parts.append("platform=\(platform)")
        }
        if let rating {
            parts.append("rating=\(rating)")
        }
        if let moodTag {
            parts.append("mood_tag=\(moodTag)")
        }
        if let tags {
            parts.append("tags=\(tags)")
        }
        if let note {
            parts.append("note=\(note)")
        }
        if let seriesName {
            parts.append("series_name=\(seriesName)")
        }
        if let episode {
            parts.append("episode=\(episode.value)")
        }
        if let season {
            parts.append("season=\(season.value)")
        }
        return parts.joined(separator: ", ")
    }

    var rawPayload: [String: Any] {
        var payload: [String: Any] = [
            "text": summary,
            "sample_source": "edge_scaffold_synthetic_music_sample",
            "date": date,
            "weekday": weekday,
            "record_type": recordType,
            "title": title,
            "synthetic": true,
        ]
        payload["time_of_day"] = timeOfDay
        payload["artist"] = artist
        payload["genre"] = genre
        payload["duration_minutes"] = durationMinutes
        payload["platform"] = platform
        payload["rating"] = rating
        payload["mood_tag"] = moodTag
        payload["tags"] = tags
        payload["note"] = note
        payload["series_name"] = seriesName
        payload["episode"] = episode?.value
        payload["season"] = season?.value
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

struct ScaffoldLossyString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected string-compatible value"
            )
        }
    }
}

extension ScaffoldMusicSample {
    struct SeedResult: Equatable {
        let sampleRecords: Int
        let writtenThisRun: Int
        let rawUnclassified: Int
        let classified: Int
        let total: Int
    }
}

enum ScaffoldMusicSampleError: LocalizedError {
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Missing bundled sample data resource: \(name).json"
        }
    }
}
