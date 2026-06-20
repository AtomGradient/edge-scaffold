// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Darwin
import Foundation
import EdgeInference

@MainActor
enum ScaffoldFeedbackSmokeRunner {
    static let launchArgument = "--scaffold-feedback-smoke"
    static let resultFileName = "scaffold_feedback_smoke_result.json"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func runAndExit() {
        Task { @MainActor in
            let report = run()
            do {
                try write(report)
            } catch {
                NSLog("[ScaffoldFeedbackSmokeRunner] failed to write report: \(error.localizedDescription)")
            }
            NSLog("[ScaffoldFeedbackSmokeRunner] completed passed=\(report.passed)")
            Darwin.exit(report.passed ? 0 : 1)
        }
    }

    private static func run() -> FeedbackSmokeReport {
        let startedAt = Date()
        let runID = "scaffold-feedback-smoke-\(Int(startedAt.timeIntervalSince1970))"
        var errors: [String] = []
        var checkpoints: [FeedbackSmokeCheckpoint] = []

        PersonalizationManager.shared.removeSmokeRecords(containing: "scaffold-feedback-smoke-")
        removeFileIfContainsSmokeMarker("training_sft.jsonl")
        removeFileIfContainsSmokeMarker("training_preferences.jsonl")
        let initialFeedbackCount = PersonalizationManager.shared.feedbackCount
        let initialCorrectionCount = PersonalizationManager.shared.correctionCount
        let initialMessages = [
            DisplayMessage(
                role: .user,
                content: "C1 smoke prompt \(runID)"
            ),
            DisplayMessage(
                role: .assistant,
                content: "C1 smoke rejected answer \(runID)"
            ),
            DisplayMessage(
                role: .user,
                content: "C1 smoke good prompt \(runID)"
            ),
            DisplayMessage(
                role: .assistant,
                content: "C1 smoke accepted answer \(runID)"
            ),
        ]

        let badOpen = ChatFeedbackFlow.applyFeedback(
            rating: "bad",
            messageIndex: 1,
            messages: initialMessages,
            correctionState: .empty
        )
        checkpoints.append(.init(
            name: "bad_opens_correction_editor",
            passed: badOpen.didOpenCorrectionEditor
                && badOpen.correctionState.isPresented
                && badOpen.correctionState.targetIndex == 1
                && badOpen.correctionState.draft.contains("rejected answer"),
            detail: "presented=\(badOpen.correctionState.isPresented) target=\(badOpen.correctionState.targetIndex.map(String.init) ?? "nil")"
        ))

        let correctionText = "C1 smoke corrected answer \(runID)"
        let badDone = ChatFeedbackFlow.submitCorrection(
            messageIndex: 1,
            correctionText: correctionText,
            messages: badOpen.messages
        )
        if let feedback = badDone.feedback {
            PersonalizationManager.shared.recordFeedback(feedback)
        }
        if let correction = badDone.correction {
            PersonalizationManager.shared.recordCorrection(correction)
        }
        checkpoints.append(.init(
            name: "bad_done_marks_message",
            passed: badDone.messages[1].feedbackRating == "bad",
            detail: "rating=\(badDone.messages[1].feedbackRating ?? "nil")"
        ))
        checkpoints.append(.init(
            name: "bad_done_writes_correction",
            passed: PersonalizationManager.shared.allCorrections.contains {
                $0.correctionText == correctionText && $0.assistantResponse.contains(runID)
            },
            detail: "corrections=\(PersonalizationManager.shared.correctionCount)"
        ))
        checkpoints.append(.init(
            name: "bad_done_persists_chat_corrections_json",
            passed: fileContains(
                documentsURL().appendingPathComponent("chat_corrections.json"),
                needle: correctionText
            ),
            detail: "file=chat_corrections.json"
        ))

        let good = ChatFeedbackFlow.applyFeedback(
            rating: "good",
            messageIndex: 3,
            messages: badDone.messages,
            correctionState: ChatFeedbackFlow.resetCorrectionState()
        )
        if let feedback = good.feedback {
            PersonalizationManager.shared.recordFeedback(feedback)
        }
        checkpoints.append(.init(
            name: "good_marks_message_without_editor",
            passed: good.messages[3].feedbackRating == "good"
                && !good.didOpenCorrectionEditor
                && !good.correctionState.isPresented,
            detail: "rating=\(good.messages[3].feedbackRating ?? "nil") presented=\(good.correctionState.isPresented)"
        ))
        checkpoints.append(.init(
            name: "good_persists_chat_feedback_json",
            passed: fileContains(
                documentsURL().appendingPathComponent("chat_feedback.json"),
                needle: "\"rating\":\"good\""
            ) && fileContains(
                documentsURL().appendingPathComponent("chat_feedback.json"),
                needle: runID
            ),
            detail: "file=chat_feedback.json"
        ))

        let sftFileName = "scaffold_feedback_smoke_sft_\(runID).jsonl"
        let preferencesFileName = "scaffold_feedback_smoke_preferences_\(runID).jsonl"
        let exports = PersonalizationManager.shared.exportTrainingDataJSONL(
            sftFileName: sftFileName,
            preferencesFileName: preferencesFileName
        )
        let sftContainsRunID = fileContains(exports.sftJSONL, needle: runID)
        let preferencesContainsCorrection = fileContains(
            exports.preferencesJSONL,
            needle: correctionText
        )
        checkpoints.append(.init(
            name: "training_sft_export_contains_good_feedback",
            passed: sftContainsRunID,
            detail: exports.sftJSONL?.lastPathComponent ?? "missing"
        ))
        checkpoints.append(.init(
            name: "training_preferences_export_contains_correction",
            passed: preferencesContainsCorrection,
            detail: exports.preferencesJSONL?.lastPathComponent ?? "missing"
        ))

        let feedbackAfter = PersonalizationManager.shared.feedbackCount
        let correctionAfter = PersonalizationManager.shared.correctionCount
        if feedbackAfter < initialFeedbackCount + 2 {
            errors.append("expected at least 2 new feedback records")
        }
        if correctionAfter < initialCorrectionCount + 1 {
            errors.append("expected at least 1 new correction record")
        }
        errors.append(contentsOf: checkpoints.filter { !$0.passed }.map(\.name))

        PersonalizationManager.shared.removeSmokeRecords(containing: runID)
        removeFile(exports.sftJSONL)
        removeFile(exports.preferencesJSONL)
        let finalFeedbackCount = PersonalizationManager.shared.feedbackCount
        let finalCorrectionCount = PersonalizationManager.shared.correctionCount
        let cleanupPassed = finalFeedbackCount == initialFeedbackCount
            && finalCorrectionCount == initialCorrectionCount
            && !fileExists(exports.sftJSONL)
            && !fileExists(exports.preferencesJSONL)
        checkpoints.append(.init(
            name: "cleanup_removes_smoke_records_and_exports",
            passed: cleanupPassed,
            detail: "feedback=\(finalFeedbackCount) corrections=\(finalCorrectionCount)"
        ))
        if !cleanupPassed {
            errors.append("cleanup_removes_smoke_records_and_exports")
        }

        let finishedAt = Date()
        return FeedbackSmokeReport(
            schemaVersion: "edge_scaffold.feedback_smoke.v1",
            startedAt: isoString(from: startedAt),
            finishedAt: isoString(from: finishedAt),
            durationMs: Int(finishedAt.timeIntervalSince(startedAt) * 1_000),
            passed: errors.isEmpty,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            runtimeMetadata: runtimeMetadata(),
            runID: runID,
            initialFeedbackCount: initialFeedbackCount,
            writtenFeedbackCount: feedbackAfter,
            finalFeedbackCount: finalFeedbackCount,
            initialCorrectionCount: initialCorrectionCount,
            writtenCorrectionCount: correctionAfter,
            finalCorrectionCount: finalCorrectionCount,
            sftExportFile: exports.sftJSONL?.lastPathComponent,
            preferencesExportFile: exports.preferencesJSONL?.lastPathComponent,
            checkpoints: checkpoints,
            errors: errors
        )
    }

    private static func write(_ report: FeedbackSmokeReport) throws {
        let url = documentsURL().appendingPathComponent(resultFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func fileContains(_ url: URL?, needle: String) -> Bool {
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return false
        }
        return text.contains(needle)
    }

    private static func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func removeFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func removeFileIfContainsSmokeMarker(_ fileName: String) {
        let url = documentsURL().appendingPathComponent(fileName)
        guard fileContains(url, needle: "scaffold-feedback-smoke-") else { return }
        removeFile(url)
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func runtimeMetadata() -> FeedbackSmokeRuntimeMetadata {
        let hostMetadata = hostBuildMetadata()
        return FeedbackSmokeRuntimeMetadata(
            edgeKitVersion: EdgeKitRuntime.version,
            edgeEngineVersion: EdgeKitRuntime.nativeRuntimeVersion,
            appBuild: FeedbackSmokeAppBuildMetadata(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                gitSHAs: hostMetadata?.gitSHAs ?? [:],
                dependencyVersions: hostMetadata?.dependencyVersions ?? [:],
                demoReadyTag: hostMetadata?.demoReadyTag,
                demoReadyTagExact: hostMetadata?.demoReadyTagExact ?? false
            )
        )
    }

    private static func hostBuildMetadata() -> FeedbackSmokeBuildMetadata? {
        let url = documentsURL().appendingPathComponent("device_test_build_metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FeedbackSmokeBuildMetadata.self, from: data)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct FeedbackSmokeReport: Encodable {
    let schemaVersion: String
    let startedAt: String
    let finishedAt: String
    let durationMs: Int
    let passed: Bool
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let runtimeMetadata: FeedbackSmokeRuntimeMetadata
    let runID: String
    let initialFeedbackCount: Int
    let writtenFeedbackCount: Int
    let finalFeedbackCount: Int
    let initialCorrectionCount: Int
    let writtenCorrectionCount: Int
    let finalCorrectionCount: Int
    let sftExportFile: String?
    let preferencesExportFile: String?
    let checkpoints: [FeedbackSmokeCheckpoint]
    let errors: [String]
}

private struct FeedbackSmokeCheckpoint: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct FeedbackSmokeBuildMetadata: Decodable {
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}

private struct FeedbackSmokeRuntimeMetadata: Encodable {
    let edgeKitVersion: String
    let edgeEngineVersion: String
    let appBuild: FeedbackSmokeAppBuildMetadata
}

private struct FeedbackSmokeAppBuildMetadata: Encodable {
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}
