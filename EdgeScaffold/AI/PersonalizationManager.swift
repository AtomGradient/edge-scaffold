// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation

@MainActor
final class PersonalizationManager: ObservableObject {

    static let shared = PersonalizationManager()

    @Published var feedbackCount: Int = 0
    @Published var correctionCount: Int = 0

    private let feedbackStore = FeedbackStore()
    private let correctionStore = CorrectionStore()

    private init() {
        feedbackCount = feedbackStore.count
        correctionCount = correctionStore.count
    }


    func recordFeedback(_ feedback: ChatFeedback) {
        feedbackStore.append(feedback)
        feedbackCount = feedbackStore.count
    }

    var allFeedback: [ChatFeedback] {
        feedbackStore.all
    }

    func recordCorrection(_ correction: ChatCorrection) {
        correctionStore.append(correction)
        correctionCount = correctionStore.count
    }

    var allCorrections: [ChatCorrection] {
        correctionStore.all
    }


    func exportTrainingDataJSONL(
        sftFileName: String = "training_sft.jsonl",
        preferencesFileName: String = "training_preferences.jsonl"
    ) -> TrainingDataExportURLs {
        TrainingDataExportURLs(
            sftJSONL: feedbackStore.exportSFTJSONL(fileName: sftFileName),
            preferencesJSONL: TrainingPreferenceExporter.export(
                feedback: feedbackStore.all,
                corrections: correctionStore.all,
                fileName: preferencesFileName
            )
        )
    }

    func exportToJSONL() -> URL? {
        feedbackStore.exportToJSONL()
    }

    func clearFeedback() {
        feedbackStore.clear()
        feedbackCount = 0
        correctionStore.clear()
        correctionCount = 0
    }

    func removeSmokeRecords(containing marker: String) {
        guard !marker.isEmpty else { return }
        feedbackStore.remove { feedback in
            feedback.userMessage.contains(marker)
                || feedback.assistantResponse.contains(marker)
        }
        correctionStore.remove { correction in
            correction.sourceInputText.contains(marker)
                || correction.assistantResponse.contains(marker)
                || correction.correctionText.contains(marker)
        }
        feedbackCount = feedbackStore.count
        correctionCount = correctionStore.count
    }
}

struct TrainingDataExportURLs {
    let sftJSONL: URL?
    let preferencesJSONL: URL?

    var exportedURLs: [URL] {
        [sftJSONL, preferencesJSONL].compactMap { $0 }
    }

    var hasExports: Bool {
        !exportedURLs.isEmpty
    }
}


struct ChatFeedback: Codable, Identifiable {
    let id: UUID
    let userMessage: String
    let assistantResponse: String
    let rating: Rating
    let timestamp: Date

    enum Rating: String, Codable {
        case good
        case bad
    }

    init(userMessage: String, assistantResponse: String, rating: Rating) {
        self.id = UUID()
        self.userMessage = userMessage
        self.assistantResponse = assistantResponse
        self.rating = rating
        self.timestamp = Date()
    }
}

struct ChatCorrection: Codable, Identifiable {
    let id: UUID
    let sourceInputText: String
    let assistantResponse: String
    let correctionText: String
    let correctionSource: String
    let isFixture: Bool
    let timestamp: Date

    init(
        sourceInputText: String,
        assistantResponse: String,
        correctionText: String,
        correctionSource: String = "user",
        isFixture: Bool = false
    ) {
        self.id = UUID()
        self.sourceInputText = sourceInputText
        self.assistantResponse = assistantResponse
        self.correctionText = correctionText
        self.correctionSource = correctionSource
        self.isFixture = isFixture
        self.timestamp = Date()
    }
}


private class FeedbackStore {
    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("chat_feedback.json")
    }

    var count: Int { all.count }

    var all: [ChatFeedback] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ChatFeedback].self, from: data)) ?? []
    }

    func append(_ feedback: ChatFeedback) {
        var items = all
        items.append(feedback)
        save(items)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func remove(where shouldRemove: (ChatFeedback) -> Bool) {
        let kept = all.filter { !shouldRemove($0) }
        save(kept)
    }

    func exportToJSONL() -> URL? {
        exportSFTJSONL(fileName: "training_data.jsonl", includeMetadata: false)
    }

    func exportSFTJSONL(
        fileName: String = "training_sft.jsonl",
        includeMetadata: Bool = true
    ) -> URL? {
        let items = all.filter { $0.rating == .good }
        guard !items.isEmpty else { return nil }

        let lines = items.map { feedback -> String in
            var entry: [String: Any] = [
                "messages": [
                    ["role": "user", "content": feedback.userMessage],
                    ["role": "assistant", "content": feedback.assistantResponse],
                ]
            ]
            if includeMetadata {
                entry["schema_version"] = "edgestudio.training.sft.v1"
                entry["source"] = "chat_feedback"
                entry["feedback_id"] = feedback.id.uuidString
                entry["rating"] = feedback.rating.rawValue
                entry["created_at"] = TrainingJSONLWriter.isoString(feedback.timestamp)
            }
            let data = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys]
            )
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }.filter { !$0.isEmpty }

        return TrainingJSONLWriter.write(lines, fileName: fileName)
    }

    private func save(_ items: [ChatFeedback]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL)
    }
}

private enum TrainingPreferenceExporter {
    static func export(
        feedback: [ChatFeedback],
        corrections: [ChatCorrection],
        fileName: String = "training_preferences.jsonl"
    ) -> URL? {
        let feedbackRecords = feedback.map(feedbackSignalRecord)
        let correctionRecords = corrections.map(correctionPairRecord)
        return TrainingJSONLWriter.writeJSONL(
            feedbackRecords + correctionRecords,
            fileName: fileName
        )
    }

    private static func feedbackSignalRecord(_ feedback: ChatFeedback) -> [String: Any] {
        [
            "schema_version": "edgestudio.training.preference.v1",
            "record_type": "kto_signal",
            "source": "chat_feedback",
            "feedback_id": feedback.id.uuidString,
            "label": feedback.rating == .good ? "positive" : "negative",
            "rating": feedback.rating.rawValue,
            "messages": [
                ["role": "user", "content": feedback.userMessage],
                ["role": "assistant", "content": feedback.assistantResponse],
            ],
            "created_at": TrainingJSONLWriter.isoString(feedback.timestamp),
        ]
    }

    private static func correctionPairRecord(_ correction: ChatCorrection) -> [String: Any] {
        [
            "schema_version": "edgestudio.training.preference.v1",
            "record_type": "dpo_pair",
            "source": "chat_correction",
            "correction_id": correction.id.uuidString,
            "prompt": [
                ["role": "user", "content": correction.sourceInputText],
            ],
            "chosen": [
                ["role": "assistant", "content": correction.correctionText],
            ],
            "rejected": [
                ["role": "assistant", "content": correction.assistantResponse],
            ],
            "correction_source": correction.correctionSource,
            "is_fixture": correction.isFixture,
            "created_at": TrainingJSONLWriter.isoString(correction.timestamp),
        ]
    }
}

private enum TrainingJSONLWriter {
    static func writeJSONL(_ records: [[String: Any]], fileName: String) -> URL? {
        let lines = records.compactMap { record -> String? in
            guard JSONSerialization.isValidJSONObject(record),
                  let data = try? JSONSerialization.data(
                    withJSONObject: record,
                    options: [.sortedKeys]
                  )
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        return write(lines, fileName: fileName)
    }

    static func write(_ lines: [String], fileName: String) -> URL? {
        guard !lines.isEmpty,
              let docs = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
              ).first
        else {
            return nil
        }
        let outputURL = docs.appendingPathComponent(fileName)
        try? lines.joined(separator: "\n").write(
            to: outputURL,
            atomically: true,
            encoding: .utf8
        )
        return outputURL
    }

    static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private class CorrectionStore {
    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("chat_corrections.json")
    }

    var count: Int { all.count }

    var all: [ChatCorrection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ChatCorrection].self, from: data)) ?? []
    }

    func append(_ correction: ChatCorrection) {
        var items = all
        items.append(correction)
        save(items)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func remove(where shouldRemove: (ChatCorrection) -> Bool) {
        let kept = all.filter { !shouldRemove($0) }
        save(kept)
    }

    private func save(_ items: [ChatCorrection]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL)
    }
}
