// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeMesh

struct ScaffoldLearningStatusProvider: LearningStatusProvider {
    let peerID: String
    let displayName: String

    func makeDeviceLearningSnapshot() async throws -> DeviceLearningSnapshot {
        let modelState = await MainActor.run {
            DeviceLearningSnapshotBuilder.ModelState(
                isLoaded: AIManager.shared.isModelLoaded,
                loadedModelID: AIManager.shared.loadedModelName,
                loadError: AIManager.shared.loadError,
                activeNeuralImprintPrefixTokenCount: AIManager.shared.neuralImprintCacheStatus?.prefixTokenCount,
                activeNeuralImprintArtifactSHA256: AIManager.shared.neuralImprintCacheStatus?.artifactSHA256
            )
        }
        let rppLastRun = DeviceLearningSnapshotBuilder.readJSONFile(named: "rpp_last_run.json")
        let neuralImprintDirectoryExists = await MainActor.run {
            AIManager.firstAvailableNeuralImprintDirectory() != nil
        }
        let toolSchemaSHA256 = await MainActor.run {
            try? AIManager.neuralImprintToolSchemaSnapshot().sha256
        }

        return DeviceLearningSnapshotBuilder.makeSnapshot(
            identity: .init(
                peerID: peerID,
                displayName: displayName,
                gitCommit: Self.deviceTestGitCommit(repositoryName: "edge-scaffold")
            ),
            modelConfig: .init(
                selectedModelID: ScaffoldConfig.modelID,
                displayName: ScaffoldConfig.modelDisplayName,
                family: ScaffoldConfig.rppModelFamily,
                quantization: DeviceLearningSnapshotBuilder.quantizationLabel(for: ScaffoldConfig.modelID)
            ),
            modelState: modelState,
            dataCounts: .init(
                eventStoreTotal: EdgeDataBootstrap.trainingSink?.eventStoreCount(),
                factsTotal: Self.factCount(status: .all),
                factsClassified: Self.factCount(status: .classifiedOnly),
                factsRawUnclassified: Self.factCount(status: .rawUnclassified)
            ),
            rppState: .init(
                runID: rppLastRun?["rpp_run_id"] as? String,
                targetLayer: (rppLastRun?["target_layer"] as? Int) ?? ScaffoldConfig.rppTargetLayer,
                aLibraryID: (rppLastRun?["a_library_id"] as? String)
                    ?? ScaffoldSampleDomainRegistry.selectedDomain.rppDirectionSetID,
                aLibrarySHA256: rppLastRun?["a_hash"] as? String
            ),
            neuralImprintDirectoryExists: neuralImprintDirectoryExists,
            toolSchemaSHA256: toolSchemaSHA256
        )
    }

    private static func factCount(status: QueryStatus) -> Int? {
        try? Edge.countFacts(status: status)
    }

    private static func deviceTestGitCommit(repositoryName: String) -> String? {
        let url = documentsURL().appendingPathComponent("device_test_build_metadata.json")
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(DeviceTestBuildMetadata.self, from: data)
        else {
            return nil
        }
        return metadata.gitSHAs[repositoryName]
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }
}

private struct DeviceTestBuildMetadata: Decodable {
    let gitSHAs: [String: String]
}
