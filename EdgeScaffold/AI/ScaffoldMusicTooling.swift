// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import EdgeSession

enum ScaffoldMusicTooling {
    static let recordsToolName = "query_media_records"
    static let listeningToolName = "query_listening_summary"

    static let toolNames = [
        recordsToolName,
        listeningToolName,
    ]

    static func registerTools(in registry: ToolRegistry = .shared) {
        registry.register(RegisteredTool(
            metadata: ToolMetadata(
                name: recordsToolName,
                description: "Query synthetic music, movie, video, podcast, and TV records by title, artist, genre, platform, mood, tags, note text, or date range. Use for exact media records, latest/recent plays, artists, titles, platforms, and evidence examples.",
                argumentsSchema: .jsonSchema(recordsArgumentsSchema),
                resultSchema: .jsonSchema(musicQueryResultSchema),
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
                name: listeningToolName,
                description: "Aggregate synthetic media time by record type, genre, platform, mood, artist, or date range. Use for exact listening minutes, current/last period totals, counts, date-range sums, media preferences, and entertainment summaries.",
                argumentsSchema: .jsonSchema(summaryArgumentsSchema),
                resultSchema: .jsonSchema(musicQueryResultSchema),
                permissions: [.readFacts],
                sensitivity: .normal,
                timeoutSeconds: 2,
                intentTags: [.exactFact, .aggregateFact]
            ),
            executor: { arguments in
                try exportSummary(arguments: arguments)
            }
        ))
    }

    private static func exportRecords(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let title = stringValue(arguments["title"])?.lowercased()
        let artist = stringValue(arguments["artist"])?.lowercased()
        let genre = stringValue(arguments["genre"])?.lowercased()
        let platform = stringValue(arguments["platform"])?.lowercased()
        let mood = stringValue(arguments["mood_tag"] ?? arguments["moodTag"] ?? arguments["mood"])?.lowercased()
        let tags = stringValue(arguments["tags"])?.lowercased()
        let text = stringValue(arguments["text"])?.lowercased()
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try mediaFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let title, !item.title.lowercased().contains(title) { return false }
            if let artist, !(item.artist?.lowercased().contains(artist) ?? false) { return false }
            if let genre, item.genre?.lowercased() != genre { return false }
            if let platform, !(item.platform?.lowercased().contains(platform) ?? false) { return false }
            if let mood, item.moodTag?.lowercased() != mood { return false }
            if let tags, !(item.tags?.lowercased().contains(tags) ?? false) { return false }
            if let text, !item.searchText.lowercased().contains(text) { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(MusicQueryResult(
            namespace: ScaffoldMusicSample.namespace,
            schema: ScaffoldMusicSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func exportSummary(arguments: [String: AuditValue]) throws -> String {
        let recordType = stringValue(arguments["record_type"] ?? arguments["recordType"])?.lowercased()
        let genre = stringValue(arguments["genre"])?.lowercased()
        let platform = stringValue(arguments["platform"])?.lowercased()
        let mood = stringValue(arguments["mood_tag"] ?? arguments["moodTag"] ?? arguments["mood"])?.lowercased()
        let artist = stringValue(arguments["artist"])?.lowercased()
        let minDuration = doubleValue(arguments["min_duration_minutes"] ?? arguments["minDurationMinutes"])
        let startDate = stringValue(arguments["start_date"] ?? arguments["startDate"])
        let endDate = stringValue(arguments["end_date"] ?? arguments["endDate"])
        let limit = boundedLimit(from: arguments["limit"], defaultValue: 12, range: 1...50)

        let allFacts = try mediaFacts()
        let filtered = allFacts.filter { item in
            if let recordType, item.recordType.lowercased() != recordType { return false }
            if let genre, item.genre?.lowercased() != genre { return false }
            if let platform, !(item.platform?.lowercased().contains(platform) ?? false) { return false }
            if let mood, item.moodTag?.lowercased() != mood { return false }
            if let artist, !(item.artist?.lowercased().contains(artist) ?? false) { return false }
            if let minDuration, (item.durationMinutes ?? 0) < minDuration { return false }
            if let startDate, item.date < startDate { return false }
            if let endDate, item.date > endDate { return false }
            return true
        }

        return try encodeToolResult(MusicQueryResult(
            namespace: ScaffoldMusicSample.namespace,
            schema: ScaffoldMusicSample.schemaName,
            totalClassified: allFacts.count,
            matchedCount: filtered.count,
            totalDurationMinutes: rounded(filtered.compactMap(\.durationMinutes).reduce(0, +)),
            groups: grouped(filtered),
            items: Array(filtered.prefix(limit)).map(\.item)
        ))
    }

    private static func mediaFacts() throws -> [MediaFact] {
        try Edge.queryFacts(
            namespace: ScaffoldMusicSample.namespace,
            status: .classifiedOnly,
            limit: 1_000
        )
        .compactMap(MediaFact.init(fact:))
        .sorted { $0.tsMs > $1.tsMs }
    }

    private static func grouped(_ facts: [MediaFact]) -> [MusicGroupSummary] {
        var groups: [String: MusicGroupSummary] = [:]
        for fact in facts {
            let key = fact.recordType
            var current = groups[key] ?? MusicGroupSummary(
                key: key,
                count: 0,
                totalDurationMinutes: 0
            )
            current.count += 1
            current.totalDurationMinutes += fact.durationMinutes ?? 0
            groups[key] = current
        }
        return groups.values
            .sorted { lhs, rhs in
                if lhs.totalDurationMinutes == rhs.totalDurationMinutes { return lhs.key < rhs.key }
                return lhs.totalDurationMinutes > rhs.totalDurationMinutes
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
          "enum": ["music", "movie", "video", "podcast_listen", "tv_series"],
          "description": "Optional media record type filter."
        },
        "title": { "type": "string", "description": "Optional title substring." },
        "artist": { "type": "string", "description": "Optional artist substring." },
        "genre": {
          "type": "string",
          "enum": ["pop", "rock", "rap", "hip_hop", "r_and_b", "folk", "jazz", "classical", "electronic", "indie", "ost", "action", "animation", "comedy", "documentary", "drama", "romance", "sci_fi", "tech", "thriller", "other"],
          "description": "Optional genre filter."
        },
        "platform": { "type": "string", "description": "Optional platform substring." },
        "mood_tag": {
          "type": "string",
          "enum": ["chill", "energetic", "focused", "happy", "intense", "melancholy", "nostalgic"],
          "description": "Optional mood tag filter."
        },
        "tags": { "type": "string", "description": "Optional tags substring." },
        "text": { "type": "string", "description": "Optional search text across title, artist, tags, note, and series." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let summaryArgumentsSchema = """
    {
      "type": "object",
      "properties": {
        "record_type": {
          "type": "string",
          "enum": ["music", "movie", "video", "podcast_listen", "tv_series"],
          "description": "Optional media record type filter."
        },
        "genre": {
          "type": "string",
          "enum": ["pop", "rock", "rap", "hip_hop", "r_and_b", "folk", "jazz", "classical", "electronic", "indie", "ost", "action", "animation", "comedy", "documentary", "drama", "romance", "sci_fi", "tech", "thriller", "other"],
          "description": "Optional genre filter."
        },
        "platform": { "type": "string", "description": "Optional platform substring." },
        "mood_tag": {
          "type": "string",
          "enum": ["chill", "energetic", "focused", "happy", "intense", "melancholy", "nostalgic"],
          "description": "Optional mood tag filter."
        },
        "artist": { "type": "string", "description": "Optional artist substring." },
        "min_duration_minutes": { "type": "number", "description": "Optional minimum duration filter." },
        "start_date": { "type": "string", "description": "Optional absolute start date in YYYY-MM-DD." },
        "end_date": { "type": "string", "description": "Optional absolute end date in YYYY-MM-DD." },
        "limit": { "type": "integer", "description": "Maximum records to return." }
      },
      "additionalProperties": false
    }
    """

    private static let musicQueryResultSchema = """
    {
      "type": "object",
      "properties": {
        "namespace": { "type": "string" },
        "schema": { "type": "string" },
        "total_classified": { "type": "integer" },
        "matched_count": { "type": "integer" },
        "total_duration_minutes": { "type": "number" },
        "groups": { "type": "array" },
        "items": { "type": "array" }
      },
      "required": ["namespace", "schema", "total_classified", "matched_count", "total_duration_minutes", "items"]
    }
    """
}

private struct MediaFact {
    let date: String
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
    let episode: String?
    let season: String?
    let tsMs: Int64

    init?(fact: Fact) {
        guard fact.schema == ScaffoldMusicSample.schemaName,
              let date = fact.payload["date"] as? String,
              let recordType = fact.payload["record_type"] as? String,
              let title = fact.payload["title"] as? String
        else {
            return nil
        }
        self.date = date
        self.recordType = recordType
        self.title = title
        self.artist = fact.payload["artist"] as? String
        self.genre = fact.payload["genre"] as? String
        self.durationMinutes = fact.payload["duration_minutes"] as? Double
        self.platform = fact.payload["platform"] as? String
        self.rating = fact.payload["rating"] as? Double
        self.moodTag = fact.payload["mood_tag"] as? String
        self.tags = fact.payload["tags"] as? String
        self.note = fact.payload["note"] as? String
        self.seriesName = fact.payload["series_name"] as? String
        self.episode = fact.payload["episode"] as? String
        self.season = fact.payload["season"] as? String
        self.tsMs = fact.tsMs
    }

    var searchText: String {
        [
            title,
            artist,
            genre,
            platform,
            moodTag,
            tags,
            note,
            seriesName,
            episode,
            season,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var item: MediaRecordItem {
        MediaRecordItem(
            date: date,
            recordType: recordType,
            title: title,
            artist: artist,
            genre: genre,
            durationMinutes: durationMinutes,
            platform: platform,
            rating: rating,
            moodTag: moodTag,
            tags: tags,
            note: note,
            seriesName: seriesName,
            episode: episode,
            season: season
        )
    }
}

private struct MusicQueryResult: Codable {
    let namespace: String
    let schema: String
    let totalClassified: Int
    let matchedCount: Int
    let totalDurationMinutes: Double
    let groups: [MusicGroupSummary]
    let items: [MediaRecordItem]

    private enum CodingKeys: String, CodingKey {
        case namespace
        case schema
        case totalClassified = "total_classified"
        case matchedCount = "matched_count"
        case totalDurationMinutes = "total_duration_minutes"
        case groups
        case items
    }
}

private struct MediaRecordItem: Codable {
    let date: String
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
    let episode: String?
    let season: String?

    private enum CodingKeys: String, CodingKey {
        case date
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
    }
}

private struct MusicGroupSummary: Codable {
    let key: String
    var count: Int
    var totalDurationMinutes: Double

    var rounded: MusicGroupSummary {
        MusicGroupSummary(
            key: key,
            count: count,
            totalDurationMinutes: ScaffoldMusicTooling.rounded(totalDurationMinutes)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case count
        case totalDurationMinutes = "total_duration_minutes"
    }
}
