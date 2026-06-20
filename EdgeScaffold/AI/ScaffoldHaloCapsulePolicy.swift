// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference
import EdgeMesh

enum ScaffoldHaloCapsulePolicy {
    static let policySchemaVersion = "edgestudio.scaffold_halo_capsule_accept_policy.v1"
    static let currentRuntimeVersion = EdgeKitRuntime.version

    static func snapshot(in registry: ToolRegistry = .shared) throws -> Snapshot {
        let toolSchemaSnapshot = try registry.toolSchemaSnapshot(
            forNames: ScaffoldSampleDomainRegistry.selectedToolNames()
        )
        return HaloCapsuleAcceptPolicy.snapshot(
            schemaVersion: policySchemaVersion,
            baseModelID: ScaffoldConfig.modelID,
            modelDisplayName: ScaffoldConfig.modelDisplayName,
            currentRuntimeVersion: currentRuntimeVersion,
            toolSchemaSnapshot: toolSchemaSnapshot,
            defaultEnableThinking: ScaffoldConfig.defaultEnableThinking
        )
    }

    static func validateOffer(
        data: Data,
        in registry: ToolRegistry = .shared
    ) throws -> OfferReceipt {
        try HaloCapsuleAcceptPolicy.validateOffer(data: data, policy: snapshot(in: registry))
    }
}

extension ScaffoldHaloCapsulePolicy {
    typealias Snapshot = HaloCapsuleAcceptPolicy.Snapshot
    typealias OfferReceipt = HaloCapsuleAcceptPolicy.OfferReceipt
}
