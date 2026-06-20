// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeHalo
import EdgeInference

final class ScaffoldHaloRuntimeAdapter: HaloEngineSession, HaloTextGenerator, @unchecked Sendable {
    private weak var aiManager: AIManager?

    init(aiManager: AIManager) {
        self.aiManager = aiManager
    }

    func tokenize(_ text: String) async throws -> [Int] {
        let runtime = try await readyRuntime()
        switch runtime {
        case .llm(let engine):
            return try await engine.tokenize(text)
        case .vlm(let engine):
            return try await engine.tokenize(text)
        }
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        let messages: [ChatMessage] = [.user(prompt)]
        var parameters = EdgeGenerateParameters.default
        parameters.maxTokens = maxTokens
        parameters.enableThinking = false

        let runtime = try await readyRuntime()
        let stream: AsyncThrowingStream<GenerateChunk, Error>
        switch runtime {
        case .llm(let engine):
            stream = engine.generate(messages: messages, parameters: parameters)
        case .vlm(let engine):
            stream = engine.generate(messages: messages, ciImages: [], parameters: parameters)
        }

        var output = ""
        for try await chunk in stream {
            output += chunk.text
        }
        return output
    }

    func captureHiddenState(tokens: [Int], layer: Int) async throws -> [Float] {
        let runtime = try await readyRuntime()
        switch runtime {
        case .llm(let engine):
            return try await engine.captureHiddenStates(
                tokens: tokens,
                targetLayer: layer
            )
        case .vlm(let engine):
            return try await engine.captureHiddenStates(
                tokens: tokens,
                targetLayer: layer
            )
        }
    }

    func restoreFullCache(
        _ snapshot: HaloCacheSnapshot,
        artifactURL: URL
    ) async throws {
        _ = snapshot
        let directory = artifactURL.deletingLastPathComponent()
        try await MainActor.run {
            guard let aiManager else {
                throw EdgeRuntimeError.loadFailed("AIManager is unavailable")
            }
            try aiManager.restoreNeuralImprintCacheForHalo(from: directory)
        }
    }

    func injectSteering(vectors: [[Float]], layers: [Int], scales: [Float]) throws {
        _ = vectors
        _ = layers
        _ = scales
        throw EdgeRuntimeError.unsupportedFeature("Scaffold Halo steering is not wired yet")
    }

    func removeSteering() throws {}

    private enum Runtime: @unchecked Sendable {
        case llm(LLMEngine)
        case vlm(VLMEngine)
    }

    private func readyRuntime() async throws -> Runtime {
        try await MainActor.run {
            guard let aiManager else {
                throw EdgeRuntimeError.loadFailed("AIManager is unavailable")
            }
            switch aiManager.modelCategory {
            case .llm:
                guard let engine = aiManager.llmEngine, engine.state == .ready else {
                    throw EdgeRuntimeError.loadFailed("No LLM model loaded")
                }
                return .llm(engine)
            case .vlm:
                guard let engine = aiManager.vlmEngine, engine.state == .ready else {
                    throw EdgeRuntimeError.loadFailed("No VLM model loaded")
                }
                return .vlm(engine)
            default:
                throw EdgeRuntimeError.unsupportedFeature("Halo runtime requires an LLM/VLM engine")
            }
        }
    }
}
