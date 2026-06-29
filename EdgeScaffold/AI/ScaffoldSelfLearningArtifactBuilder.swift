// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeHalo
import EdgeInference
import Tokenizers

@MainActor
final class ScaffoldSelfLearningArtifactBuilder: SelfLearningArtifactBuilder {
    private let aiManager: AIManager

    init(aiManager: AIManager = .shared) {
        self.aiManager = aiManager
    }

    func renderNeuralImprintPrefix(
        request: SelfLearningPrefixRequest
    ) async throws -> SelfLearningRenderedPrefix {
        let runtime = try aiManager.readyNeuralImprintRuntime()
        let tools = try Self.readOnlyToolSpecs()
        let render = try await runtime.renderNeuralImprintPrefix(
            profileBody: request.profileBody,
            tools: tools,
            parameters: AIManager.defaultParameters(enableThinking: request.enableThinking)
        )
        return SelfLearningRenderedPrefix(
            systemPrompt: render.systemPrompt,
            renderedPrefix: render.renderedPrefix,
            prefixTokenIDs: render.prefixTokenIDs,
            enableThinking: render.enableThinking
        )
    }

    func captureNeuralImprintArtifact(
        request: SelfLearningArtifactCaptureRequest
    ) async throws -> HaloCapsule {
        let runtime = try aiManager.readyNeuralImprintRuntime()
        let toolSchemaSnapshot = try Self.readOnlyToolSchemaSnapshot()
        let status = try await runtime.captureNeuralImprintArtifact(
            request: NeuralImprintArtifactCaptureRequest(
                outputDirectory: request.outputDirectory,
                renderedPrefix: request.renderedPrefix.renderedPrefix,
                prefixTokenIDs: request.renderedPrefix.prefixTokenIDs,
                profileBody: request.prefixRequest.profileBody,
                toolSchemaSnapshot: toolSchemaSnapshot,
                modelID: request.prefixRequest.modelID ?? ScaffoldConfig.modelID,
                systemPrompt: request.renderedPrefix.systemPrompt,
                enableThinking: request.renderedPrefix.enableThinking,
                createdAt: request.createdAt,
                createdBy: request.createdBy,
                writerVersion: "edge-scaffold.halo_self_learning_capture.v1",
                cacheBackendVersion: AIManager.neuralImprintCacheBackendVersion
            )
        )
        return try NeuralImprintHaloCapsuleMapper.capsule(
            kind: request.kind,
            status: NeuralImprintArtifactStatus(
                directory: status.directory,
                artifactURL: status.artifactURL,
                metadataURL: status.metadataURL,
                modelID: status.modelID,
                artifactSHA256: status.artifactSHA256,
                prefixTokenCount: status.prefixTokenCount,
                enableThinking: status.enableThinking,
                cacheBackend: status.cacheBackend,
                cacheBackendVersion: status.cacheBackendVersion
            ),
            renderedPrefix: request.renderedPrefix
        )
    }

    private static func readOnlyToolSpecs() throws -> [ToolSpec] {
        try readOnlyToolMetadata().map { try $0.toolSpec() }
    }

    private static func readOnlyToolSchemaSnapshot() throws -> ToolSchemaSnapshot {
        try AIManager.neuralImprintToolSchemaSnapshot()
    }

    private static func readOnlyToolMetadata() -> [ToolMetadata] {
        AIManager.neuralImprintToolMetadata()
    }
}
