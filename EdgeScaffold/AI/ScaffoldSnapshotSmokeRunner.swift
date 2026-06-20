// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Darwin
import Foundation
import EdgeMesh

@MainActor
enum ScaffoldSnapshotSmokeRunner {
    static let launchArgument = "--scaffold-snapshot-smoke"
    static let resultFileName = "scaffold_snapshot_smoke_result.json"
    private static let expectedRepositoryName = "edge-scaffold"

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func runAndExit() {
        Task { @MainActor in
            let report = await run()
            do {
                try write(report)
            } catch {
                NSLog("[ScaffoldSnapshotSmokeRunner] failed to write report: \(error.localizedDescription)")
            }
            NSLog("[ScaffoldSnapshotSmokeRunner] completed passed=\(report.passed)")
            Darwin.exit(report.passed ? 0 : 1)
        }
    }

    private static func run() async -> SnapshotSmokeReport {
        let startedAt = Date()
        var errors: [String] = []
        var checkpoints: [SnapshotSmokeCheckpoint] = []
        let expectedGitCommit = hostBuildMetadata()?.gitSHAs[expectedRepositoryName]
        var snapshot: DeviceLearningSnapshot?

        do {
            snapshot = try await ScaffoldLearningStatusProvider(
                peerID: MeshManager.shared.localPeerId,
                displayName: MeshManager.shared.localDisplayName
            ).makeDeviceLearningSnapshot()
            checkpoints.append(.init(
                name: "snapshot_generated",
                passed: true,
                detail: snapshot?.schemaVersion ?? "missing"
            ))
        } catch {
            errors.append("snapshot_generated")
            checkpoints.append(.init(
                name: "snapshot_generated",
                passed: false,
                detail: error.localizedDescription
            ))
        }

        let gitCommit = snapshot?.identity.gitCommit
        let gitCommitMatches = expectedGitCommit != nil && gitCommit == expectedGitCommit
        checkpoints.append(.init(
            name: "git_commit_matches_build_metadata",
            passed: gitCommitMatches,
            detail: "expected=\(expectedGitCommit ?? "nil") actual=\(gitCommit ?? "nil")"
        ))
        if !gitCommitMatches {
            errors.append("git_commit_matches_build_metadata")
        }

        let finishedAt = Date()
        return SnapshotSmokeReport(
            schemaVersion: "edge_scaffold.snapshot_smoke.v1",
            startedAt: isoString(from: startedAt),
            finishedAt: isoString(from: finishedAt),
            durationMs: Int(finishedAt.timeIntervalSince(startedAt) * 1_000),
            passed: errors.isEmpty,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            expectedRepositoryName: expectedRepositoryName,
            expectedGitCommit: expectedGitCommit,
            snapshot: snapshot,
            checkpoints: checkpoints,
            errors: errors
        )
    }

    private static func write(_ report: SnapshotSmokeReport) throws {
        let url = documentsURL().appendingPathComponent(resultFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func hostBuildMetadata() -> SnapshotSmokeBuildMetadata? {
        let url = documentsURL().appendingPathComponent("device_test_build_metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SnapshotSmokeBuildMetadata.self, from: data)
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SnapshotSmokeReport: Encodable {
    let schemaVersion: String
    let startedAt: String
    let finishedAt: String
    let durationMs: Int
    let passed: Bool
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let expectedRepositoryName: String
    let expectedGitCommit: String?
    let snapshot: DeviceLearningSnapshot?
    let checkpoints: [SnapshotSmokeCheckpoint]
    let errors: [String]
}

private struct SnapshotSmokeCheckpoint: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct SnapshotSmokeBuildMetadata: Decodable {
    let gitSHAs: [String: String]
}
