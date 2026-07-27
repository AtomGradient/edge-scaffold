// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import CoreImage
import EdgeHalo
import EdgeInference
import EdgeModelKit
import EdgeSession
import Tokenizers

enum ModelLoadSource: String {
    case documents = "Documents"
    case cache = "Local Cache"
    case bundle = "Bundle"
    case odr = "ODR"
    case remote = "HuggingFace"
    case none = "Not Loaded"
}

struct ModelInstallPathDiagnostic: Equatable {
    enum Status: Equatable {
        case valid
        case expectedDirectoryMissing
        case incompleteExpectedDirectory
        case modelFilesAtDocumentsRoot
    }

    let status: Status
    let expectedDirectory: String
    let misplacedRootFiles: [String]
    let missingExpectedFiles: [String]

    var isActionable: Bool {
        status != .valid
    }

    var message: String {
        switch status {
        case .valid:
            return "Documents model path is valid"
        case .expectedDirectoryMissing:
            return "Local model not found in \(expectedDirectory)"
        case .incompleteExpectedDirectory:
            let missing = missingExpectedFiles.joined(separator: ", ")
            return "Model directory is missing \(missing)"
        case .modelFilesAtDocumentsRoot:
            return "Model files found at Documents root; move them into \(expectedDirectory)"
        }
    }
}

enum ScaffoldNeuralImprintRuntime {
    case llm(LLMEngine)
    case vlm(VLMEngine)

    var state: EngineState {
        switch self {
        case .llm(let engine): return engine.state
        case .vlm(let engine): return engine.state
        }
    }

    var activeNeuralImprintCache: NeuralImprintRuntimeCacheStatus? {
        switch self {
        case .llm(let engine): return engine.activeNeuralImprintCache
        case .vlm(let engine): return engine.activeNeuralImprintCache
        }
    }

    var missingModelMessage: String {
        switch self {
        case .llm: return "No LLM model loaded"
        case .vlm: return "No VLM model loaded"
        }
    }

    func renderNeuralImprintPrefix(
        profileBody: String,
        tools: [ToolSpec],
        parameters: EdgeGenerateParameters
    ) async throws -> NeuralImprintPrefixRender {
        switch self {
        case .llm(let engine):
            return try await engine.renderNeuralImprintPrefix(
                profileBody: profileBody,
                tools: tools,
                parameters: parameters
            )
        case .vlm(let engine):
            return try await engine.renderNeuralImprintPrefix(
                profileBody: profileBody,
                tools: tools,
                parameters: parameters
            )
        }
    }

    func renderPromptTokenIDs(
        messages: [ChatMessage],
        tools: [ToolSpec]?,
        parameters: EdgeGenerateParameters
    ) async throws -> [Int] {
        switch self {
        case .llm(let engine):
            return try await engine.renderPromptTokenIDs(
                messages: messages,
                tools: tools,
                parameters: parameters
            )
        case .vlm(let engine):
            return try await engine.renderPromptTokenIDs(
                messages: messages,
                tools: tools,
                parameters: parameters
            )
        }
    }

    func captureNeuralImprintArtifact(
        request: NeuralImprintArtifactCaptureRequest
    ) async throws -> NeuralImprintRuntimeCacheStatus {
        switch self {
        case .llm(let engine):
            return try await engine.captureNeuralImprintArtifact(request: request)
        case .vlm(let engine):
            return try await engine.captureNeuralImprintArtifact(request: request)
        }
    }

    func restoreNeuralImprintCache(
        from directory: URL
    ) throws -> NeuralImprintRuntimeCacheStatus {
        switch self {
        case .llm(let engine):
            return try engine.restoreNeuralImprintCache(from: directory)
        case .vlm(let engine):
            return try engine.restoreNeuralImprintCache(from: directory)
        }
    }

    func unloadNeuralImprintCache() {
        switch self {
        case .llm(let engine):
            engine.unloadNeuralImprintCache()
        case .vlm(let engine):
            engine.unloadNeuralImprintCache()
        }
    }
}

@MainActor
final class AIManager: ObservableObject {

    static let shared = AIManager()

    let llmEngine: LLMEngine?
    let vlmEngine: VLMEngine?
    let ttsEngine: TTSEngine?
    let sttEngine: STTEngine?

    let stateManager = AIStateManager.shared
    let odrLoader = ODRModelLoader()
    private lazy var haloRuntimeAdapter = ScaffoldHaloRuntimeAdapter(aiManager: self)
    private lazy var edgeHalo = EdgeHaloRuntime(
        engine: haloRuntimeAdapter,
        generator: haloRuntimeAdapter
    )
    lazy var selfLearningCoordinator = SelfLearningCoordinator(
        artifactBuilder: ScaffoldSelfLearningArtifactBuilder(aiManager: self),
        capsuleActivator: edgeHalo
    )

    @Published var isModelLoaded = false
    @Published var loadingProgress: Double = 0
    @Published var loadError: String?
    @Published var loadSource: ModelLoadSource = .none
    @Published var neuralImprintCacheStatus: NeuralImprintRuntimeCacheStatus?
    @Published var neuralImprintCacheError: String?
    @Published private(set) var currentGenerationTokenCount: Int?
    var generationTokenCountObserver: ((Int) -> Void)?

    @Published var lastLoadedDirectory: URL?

    var modelCategory: ModelCategory { ScaffoldConfig.modelCategory }

    var engine: LLMEngine { llmEngine ?? LLMEngine() }

    func readyNeuralImprintRuntime() throws -> ScaffoldNeuralImprintRuntime {
        let runtime: ScaffoldNeuralImprintRuntime
        switch modelCategory {
        case .llm:
            guard let engine = llmEngine else {
                throw EdgeRuntimeError.loadFailed("No LLM engine")
            }
            runtime = .llm(engine)
        case .vlm:
            guard let engine = vlmEngine else {
                throw EdgeRuntimeError.loadFailed("No VLM engine")
            }
            runtime = .vlm(engine)
        case .tts, .stt:
            throw EdgeRuntimeError.unsupportedFeature("Neural Imprint requires an LLM/VLM engine")
        }
        guard runtime.state == .ready else {
            throw EdgeRuntimeError.loadFailed(runtime.missingModelMessage)
        }
        return runtime
    }

    private func neuralImprintRuntimeIfReady() -> ScaffoldNeuralImprintRuntime? {
        switch modelCategory {
        case .llm:
            guard let engine = llmEngine, engine.state == .ready else { return nil }
            return .llm(engine)
        case .vlm:
            guard let engine = vlmEngine, engine.state == .ready else { return nil }
            return .vlm(engine)
        case .tts, .stt:
            return nil
        }
    }

    private init() {
        switch ScaffoldConfig.modelCategory {
        case .llm:
            llmEngine = LLMEngine()
            vlmEngine = nil
            ttsEngine = nil
            sttEngine = nil
        case .vlm:
            llmEngine = nil
            vlmEngine = VLMEngine()
            ttsEngine = nil
            sttEngine = nil
        case .tts:
            llmEngine = nil
            vlmEngine = nil
            ttsEngine = TTSEngine()
            sttEngine = nil
        case .stt:
            llmEngine = nil
            vlmEngine = nil
            ttsEngine = nil
            sttEngine = STTEngine()
        }
    }


    var engineState: EngineState {
        switch modelCategory {
        case .llm: return llmEngine?.state ?? .idle
        case .vlm: return vlmEngine?.state ?? .idle
        case .tts: return ttsEngine?.state ?? .idle
        case .stt: return sttEngine?.isLoaded == true ? .ready : .idle
        }
    }

    var loadedModelName: String? {
        switch modelCategory {
        case .llm:
            return llmEngine?.loadedConfig?.familyName
                ?? lastLoadedDirectory?.lastPathComponent
        case .vlm: return "VLM Model"
        case .tts: return "TTS Model"
        case .stt: return sttEngine?.loadedModelName ?? "STT Model"
        }
    }


    func loadSelectedModel() async {
        let config = stateManager.selectedConfig
        await loadModel(config: config)
    }

    func loadModel(config: ModelConfig) async {
        guard engineState != .loading else { return }
        loadError = nil
        loadingProgress = 0
        loadSource = .none

        let docsModelID = ScaffoldConfig.modelID
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(docsModelID, isDirectory: true)
        if let docsURL, FileManager.default.fileExists(atPath: docsURL.path) {
            if await tryLoadLocal(directory: docsURL) {
                loadSource = .documents
                stateManager.isModelDownloaded = true
                stateManager.setLastLoadedModel(docsModelID)
                await restorePersonalizationStateAfterModelLoad()
                return
            }
        }

        if ModelCache.shared.isCached(config) {
            let localURL = ModelCache.shared.cachedURL(for: config)
            if await tryLoadLocal(directory: localURL) {
                loadSource = .cache
                stateManager.isModelDownloaded = true
                stateManager.setLastLoadedModel(config.modelID)
                await restorePersonalizationStateAfterModelLoad()
                return
            }
        }

        if let bundleName = ScaffoldConfig.bundleModelName,
           let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: nil) {
            if await tryLoadLocal(directory: bundleURL) {
                loadSource = .bundle
                stateManager.isModelDownloaded = true
                stateManager.setLastLoadedModel(config.modelID)
                await restorePersonalizationStateAfterModelLoad()
                return
            }
        }

        do {
            let tag = ScaffoldConfig.modelODRTag
            let available = await odrLoader.isAvailable(tag: tag)
            if available {
                let bundle = try await odrLoader.download(tag: tag)
                if let modelPath = bundle.path(forResource: ScaffoldConfig.modelID, ofType: nil) {
                    let url = URL(fileURLWithPath: modelPath)
                    if await tryLoadLocal(directory: url) {
                        loadSource = .odr
                        stateManager.isModelDownloaded = true
                        stateManager.setLastLoadedModel(config.modelID)
                        await restorePersonalizationStateAfterModelLoad()
                        return
                    }
                }
            }
        } catch {
            debugPrint("[AIManager] ODR load failed: \(error)")
        }

        if modelCategory == .llm, let llm = llmEngine {
            do {
                try await llm.load(config: config) { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.loadingProgress = p
                    }
                }
                isModelLoaded = true
                loadSource = .remote
                stateManager.isModelDownloaded = true
                stateManager.setLastLoadedModel(config.modelID)
                await restorePersonalizationStateAfterModelLoad()
            } catch {
                loadError = error.localizedDescription
                isModelLoaded = false
            }
        } else if modelCategory == .vlm, let vlm = vlmEngine {
            do {
                try await vlm.load(config: config) { [weak self] p in
                    Task { @MainActor [weak self] in
                        self?.loadingProgress = p
                    }
                }
                isModelLoaded = true
                loadSource = .remote
                stateManager.isModelDownloaded = true
                stateManager.setLastLoadedModel(config.modelID)
                await restorePersonalizationStateAfterModelLoad()
            } catch {
                loadError = error.localizedDescription
                isModelLoaded = false
            }
        } else {
            loadError = "TTS/STT models must be loaded locally"
            isModelLoaded = false
        }
    }

    private func tryLoadLocal(directory: URL) async -> Bool {
        let progressHandler: (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.loadingProgress = p
            }
        }

        do {
            switch modelCategory {
            case .llm:
                try await llmEngine?.loadLocal(directory: directory, onProgress: progressHandler)
            case .vlm:
                try await vlmEngine?.loadLocal(directory: directory, onProgress: progressHandler)
            case .tts:
                try await ttsEngine?.loadLocal(directory: directory, onProgress: progressHandler)
            case .stt:
                try await sttEngine?.loadLocal(directory: directory)
            }
            isModelLoaded = true
            lastLoadedDirectory = directory
            return true
        } catch {
            debugPrint("[AIManager] Local load failed: \(error)")
            return false
        }
    }


    private static let generationPoliciesConfigured: Void = {
        var chat = EdgeGenerateParameters.default
        chat.temperature = ScaffoldConfig.defaultTemperature
        chat.topK = ScaffoldConfig.defaultTopK
        chat.topP = ScaffoldConfig.defaultTopP
        chat.maxTokens = ScaffoldConfig.defaultMaxTokens
        GenerationPolicyRegistry.shared.register(chat, forModelID: ScaffoldConfig.modelID, useCase: .chat)
        GenerationPolicyRegistry.shared.register(chat, forModelID: ScaffoldConfig.modelID, useCase: .toolCall)
    }()

    static func defaultParameters(
        useCase: GenerationUseCase = .chat,
        enableThinking: Bool? = nil
    ) -> EdgeGenerateParameters {
        _ = generationPoliciesConfigured
        var params = GenerationPolicyRegistry.shared.parameters(
            forModelID: ScaffoldConfig.modelID,
            useCase: useCase
        )
        params.enableThinking = enableThinking ?? ScaffoldConfig.defaultEnableThinking
        return params
    }

    func generate(
        messages: [ChatMessage],
        ciImages: [CIImage] = [],
        tools: [ToolSpec]? = nil,
        onToolCall: (@Sendable (ToolCall) async throws -> String)? = nil,
        parameters: EdgeGenerateParameters? = nil
    ) -> AsyncThrowingStream<String, Error> {
        currentGenerationTokenCount = nil
        generationTokenCountObserver?(0)
        let parameters = parameters ?? AIManager.defaultParameters()
        let modelCategory = self.modelCategory
        let llmEngine = self.llmEngine
        let vlmEngine = self.vlmEngine
        let sustainabilityEnabled = ScaffoldConfig.enableSustainability
        return AsyncThrowingStream { continuation in
            let generationTask = Task.detached(priority: .userInitiated) {
                var tokenCount = 0
                do {
                    try Task.checkCancellation()

                    switch modelCategory {
                    case .llm:
                        guard let llm = llmEngine else { throw EdgeRuntimeError.loadFailed("No LLM engine") }
                        let stream = await llm.generate(messages: messages, tools: tools, onToolCall: onToolCall, parameters: parameters)
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            if let generatedTokenCount = chunk.generatedTokenCount {
                                tokenCount = generatedTokenCount
                                await MainActor.run {
                                    AIManager.shared.currentGenerationTokenCount = generatedTokenCount
                                    AIManager.shared.generationTokenCountObserver?(generatedTokenCount)
                                }
                            } else {
                                tokenCount += 1
                            }
                            if !chunk.text.isEmpty {
                                continuation.yield(chunk.text)
                            }
                        }
                    case .vlm:
                        guard let vlm = vlmEngine else { throw EdgeRuntimeError.loadFailed("No VLM engine") }
                        let stream = await vlm.generate(messages: messages, ciImages: ciImages, tools: tools, onToolCall: onToolCall, parameters: parameters)
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            if let generatedTokenCount = chunk.generatedTokenCount {
                                tokenCount = generatedTokenCount
                                await MainActor.run {
                                    AIManager.shared.currentGenerationTokenCount = generatedTokenCount
                                    AIManager.shared.generationTokenCountObserver?(generatedTokenCount)
                                }
                            } else {
                                tokenCount += 1
                            }
                            if !chunk.text.isEmpty {
                                continuation.yield(chunk.text)
                            }
                        }
                    case .tts:
                        throw EdgeRuntimeError.loadFailed("Use speak() for TTS models")
                    case .stt:
                        throw EdgeRuntimeError.loadFailed("Use transcribe() for STT models")
                    }

                    await MainActor.run {
                        AIStateManager.shared.recordTokens(tokenCount)
                        if sustainabilityEnabled {
                            CarbonSavingsManager.shared.recordTokens(input: 0, output: tokenCount)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                generationTask.cancel()
            }
        }
    }

    func chat(_ userMessage: String) -> AsyncThrowingStream<String, Error> {
        var messages: [ChatMessage] = []
        messages.append(.system(ScaffoldConfig.defaultSystemPrompt))
        messages.append(.user(userMessage))
        return generate(messages: messages)
    }

    func chatWithImage(_ userMessage: String, ciImages: [CIImage]) -> AsyncThrowingStream<String, Error> {
        var messages: [ChatMessage] = []
        messages.append(.system(ScaffoldConfig.defaultSystemPrompt))
        messages.append(.user(userMessage))
        return generate(messages: messages, ciImages: ciImages)
    }


    func speak(_ text: String, voice: String? = nil) async throws -> AudioResult {
        guard let tts = ttsEngine else {
            throw EdgeRuntimeError.loadFailed("No TTS engine loaded")
        }
        return try await tts.speak(text, voice: voice ?? ScaffoldConfig.defaultTTSSpeaker)
    }

    func speakStream(_ text: String, voice: String? = nil, instruct: String? = nil) -> AsyncThrowingStream<TTSEvent, Error> {
        guard let tts = ttsEngine else {
            return AsyncThrowingStream { $0.finish(throwing: EdgeRuntimeError.loadFailed("No TTS engine loaded")) }
        }
        if let instruct {
            return tts.speakStream(text, instruct: instruct)
        }
        return tts.speakStream(text, voice: voice ?? ScaffoldConfig.defaultTTSSpeaker)
    }

    var availableSpeakers: [String] {
        ttsEngine?.availableSpeakers ?? []
    }

    var ttsModelType: String {
        ttsEngine?.ttsModelType ?? "unknown"
    }


    func transcribe(audioURL: URL, language: String? = nil) async throws -> TranscriptionResult {
        guard let stt = sttEngine else {
            throw EdgeRuntimeError.loadFailed("No STT engine loaded")
        }
        return try await stt.transcribe(audioURL: audioURL, language: language)
    }

    func transcribeStream(audioURL: URL, language: String? = nil) -> AsyncThrowingStream<STTStreamEvent, Error> {
        guard let stt = sttEngine else {
            return AsyncThrowingStream { $0.finish(throwing: EdgeRuntimeError.loadFailed("No STT engine loaded")) }
        }
        return stt.transcribeStream(audioURL: audioURL, language: language)
    }

    func transcribe(samples: [Float], sampleRate: Int = 16000, language: String? = nil) async throws -> TranscriptionResult {
        guard let stt = sttEngine else {
            throw EdgeRuntimeError.loadFailed("No STT engine loaded")
        }
        return try await stt.transcribe(samples: samples, sampleRate: sampleRate, language: language)
    }


    var hasNeuralImprintCache: Bool {
        neuralImprintCacheStatus != nil
    }

    static let neuralImprintRestoreEnabledDefaultsKey = "neural_imprint_restore_enabled"

    var isNeuralImprintRestoreEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.neuralImprintRestoreEnabledDefaultsKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.neuralImprintRestoreEnabledDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.neuralImprintRestoreEnabledDefaultsKey)
        }
    }

    func setNeuralImprintRestoreEnabled(_ enabled: Bool, reloadIfLoaded: Bool = true) {
        guard isNeuralImprintRestoreEnabled != enabled else { return }
        isNeuralImprintRestoreEnabled = enabled
        neuralImprintCacheStatus = nil
        neuralImprintCacheError = nil
        writeNeuralImprintRestoreReceipt(
            status: nil,
            outcome: enabled ? "enabled_pending_reload" : "disabled_pending_reload",
            error: nil
        )
        guard reloadIfLoaded, isModelLoaded else { return }
        unloadModel()
        guard stateManager.isAIEnabled,
              stateManager.isModelDownloaded || Self.isDocumentsModelAvailable() else { return }
        Task { await loadSelectedModel() }
    }

    var neuralImprintCacheDirectory: URL? {
        neuralImprintCacheStatus?.directory
    }

    static var documentsModelDirectory: URL {
        documentsDirectory.appendingPathComponent(ScaffoldConfig.modelID, isDirectory: true)
    }

    static func validateDocumentsModelInstall() -> ModelInstallPathDiagnostic {
        let directory = documentsModelDirectory
        let fileManager = FileManager.default
        let expectedDirectory = "Documents/\(ScaffoldConfig.modelID)"
        let requiredFiles = ["config.json", "tokenizer_config.json"]
        let missingFiles = requiredFiles.filter {
            !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let knownRootFiles = rootModelFileNames.filter {
            fileManager.fileExists(atPath: documentsDirectory.appendingPathComponent($0).path)
        }
        let rootWeightFiles = ((try? fileManager.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .map(\.lastPathComponent)
            .filter(Self.isLikelyModelWeightFile)
        let misplacedRootFiles = Array(Set(knownRootFiles + rootWeightFiles)).sorted()

        if !misplacedRootFiles.isEmpty {
            return ModelInstallPathDiagnostic(
                status: .modelFilesAtDocumentsRoot,
                expectedDirectory: expectedDirectory,
                misplacedRootFiles: misplacedRootFiles,
                missingExpectedFiles: missingFiles
            )
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return ModelInstallPathDiagnostic(
                status: .expectedDirectoryMissing,
                expectedDirectory: expectedDirectory,
                misplacedRootFiles: [],
                missingExpectedFiles: requiredFiles
            )
        }
        guard missingFiles.isEmpty, isDocumentsModelAvailable() else {
            return ModelInstallPathDiagnostic(
                status: .incompleteExpectedDirectory,
                expectedDirectory: expectedDirectory,
                misplacedRootFiles: [],
                missingExpectedFiles: missingFiles.isEmpty ? ["model weights"] : missingFiles
            )
        }
        return ModelInstallPathDiagnostic(
            status: .valid,
            expectedDirectory: expectedDirectory,
            misplacedRootFiles: [],
            missingExpectedFiles: []
        )
    }

    private static let rootModelFileNames = [
        "._____temp",
        ".msc",
        ".mv",
        "README.md",
        "chat_template.jinja",
        "config.json",
        "configuration.json",
        "model.safetensors.index.json",
        "model.safetensors",
        "preprocessor_config.json",
        "processor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "video_preprocessor_config.json",
        "vocab.json",
    ]

    private static func isLikelyModelWeightFile(_ name: String) -> Bool {
        name == "model.safetensors" || (name.hasPrefix("model-") && name.hasSuffix(".safetensors"))
    }

    static func isDocumentsModelAvailable() -> Bool {
        let directory = documentsModelDirectory
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              fileManager.fileExists(atPath: directory.appendingPathComponent("tokenizer_config.json").path) else {
            return false
        }

        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexURL.path) {
            let weightFiles = referencedWeightFiles(in: indexURL, under: directory)
            return !weightFiles.isEmpty && weightFiles.allSatisfy {
                fileManager.fileExists(atPath: $0.path)
            }
        }

        let weightFiles = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return weightFiles.contains { $0.lastPathComponent.hasSuffix(".safetensors") }
    }

    @discardableResult
    func restoreNeuralImprintCacheIfAvailable() async -> Bool {
        guard let runtime = neuralImprintRuntimeIfReady() else { return false }
        guard let directory = Self.firstAvailableNeuralImprintDirectory() else {
            neuralImprintCacheStatus = nil
            neuralImprintCacheError = nil
            writeNeuralImprintRestoreReceipt(status: nil, outcome: "no_artifact", error: nil)
            return false
        }

        do {
            let status = try runtime.restoreNeuralImprintCache(from: directory)
            neuralImprintCacheStatus = status
            neuralImprintCacheError = nil
            NSLog(
                "[AIManager] Neural Imprint cache restored: %@ prefix=%d",
                directory.path,
                status.prefixTokenCount
            )
            writeNeuralImprintRestoreReceipt(status: status, outcome: "restored", error: nil)
            return true
        } catch {
            neuralImprintCacheStatus = nil
            neuralImprintCacheError = error.localizedDescription
            writeNeuralImprintRestoreReceipt(status: nil, outcome: "failed", error: error.localizedDescription)
            NSLog("[AIManager] Neural Imprint restore failed: \(error)")
            return false
        }
    }

    @discardableResult
    func buildAndActivateSelfLearningNeuralImprint(
        kind: SelfLearningArtifactKind,
        profileBody: String
    ) async throws -> NeuralImprintRuntimeCacheStatus {
        let runtime = try readyNeuralImprintRuntime()

        let previousDirectory = neuralImprintCacheStatus?.directory ?? Self.firstAvailableNeuralImprintDirectory()
        if runtime.activeNeuralImprintCache != nil {
            runtime.unloadNeuralImprintCache()
            neuralImprintCacheStatus = nil
        }

        let fileManager = FileManager.default
        let finalDirectory = Self.documentsDirectory.appendingPathComponent("neural_imprint", isDirectory: true)
        let buildDirectory = Self.documentsDirectory.appendingPathComponent(
            "neural_imprint.build-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: buildDirectory)
        }

        do {
            let toolSchemaSnapshot = try Self.neuralImprintToolSchemaSnapshot()
            let prefixRequest = SelfLearningPrefixRequest(
                kind: kind,
                profileBody: profileBody,
                toolSchemaJSON: String(data: toolSchemaSnapshot.jsonData, encoding: .utf8) ?? "{}",
                modelID: ScaffoldConfig.modelID,
                enableThinking: false
            )
            let capsule = try await selfLearningCoordinator.buildArtifact(
                prefixRequest: prefixRequest,
                outputDirectory: buildDirectory
            )
            try Self.installNeuralImprintBuildDirectory(
                buildDirectory,
                replacing: finalDirectory
            )
            let finalCapsule = HaloCapsule(
                manifest: capsule.manifest,
                artifactURL: finalDirectory.appendingPathComponent(LLMEngine.neuralImprintArtifactFileName)
            )
            try await selfLearningCoordinator.activate(
                finalCapsule,
                currentRequirements: finalCapsule.manifest.requirements
            )
            guard let status = neuralImprintCacheStatus else {
                throw EdgeRuntimeError.loadFailed("Neural Imprint restore did not publish a status")
            }
            NSLog(
                "[AIManager] Self-learning Neural Imprint captured and restored: %@ prefix=%d kind=%@",
                finalDirectory.path,
                status.prefixTokenCount,
                kind.rawValue
            )
            return status
        } catch {
            neuralImprintCacheStatus = nil
            neuralImprintCacheError = error.localizedDescription
            writeNeuralImprintRestoreReceipt(
                status: nil,
                outcome: "capture_failed",
                error: error.localizedDescription
            )
            if let previousDirectory,
               Self.neuralImprintDirectoryContainsArtifact(previousDirectory),
               let status = try? runtime.restoreNeuralImprintCache(from: previousDirectory) {
                neuralImprintCacheStatus = status
                neuralImprintCacheError = nil
                NSLog(
                    "[AIManager] restored previous Neural Imprint after capture failure: %@",
                    previousDirectory.path
                )
            }
            throw error
        }
    }

    @discardableResult
    func buildAndActivateCombinedNeuralImprint(
        profileBody: String
    ) async throws -> NeuralImprintRuntimeCacheStatus {
        try await buildAndActivateSelfLearningNeuralImprint(
            kind: .combinedKV,
            profileBody: profileBody
        )
    }

    @discardableResult
    func buildAndActivateToolsOnlyNeuralImprint() async throws -> NeuralImprintRuntimeCacheStatus {
        let status = try await buildAndActivateSelfLearningNeuralImprint(
            kind: .toolsOnlyKV,
            profileBody: Self.toolsOnlyNeuralImprintProfileBody
        )
        NSLog(
            "[AIManager] Tools-only Neural Imprint cache captured and restored: prefix=%d",
            status.prefixTokenCount
        )
        return status
    }

    @discardableResult
    func restoreNeuralImprintCacheForHalo(
        from directory: URL
    ) throws -> NeuralImprintRuntimeCacheStatus {
        let runtime = try readyNeuralImprintRuntime()
        let status = try runtime.restoreNeuralImprintCache(from: directory)
        neuralImprintCacheStatus = status
        neuralImprintCacheError = nil
        writeNeuralImprintRestoreReceipt(
            status: status,
            outcome: "captured_and_restored",
            error: nil
        )
        return status
    }

    @discardableResult
    func installAndRestoreNeuralImprintCacheFromHaloPackage(
        at packageDirectory: URL
    ) async throws -> NeuralImprintRuntimeCacheStatus {
        let runtime = try readyNeuralImprintRuntime()

        let fileManager = FileManager.default
        let finalDirectory = Self.documentsDirectory.appendingPathComponent("neural_imprint", isDirectory: true)
        let backupDirectory = Self.documentsDirectory.appendingPathComponent(
            "neural_imprint.previous-\(UUID().uuidString)",
            isDirectory: true
        )
        let failedDirectory = Self.documentsDirectory.appendingPathComponent(
            "neural_imprint.failed-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedExistingToBackup = false

        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.moveItem(at: finalDirectory, to: backupDirectory)
            movedExistingToBackup = true
        }

        do {
            try fileManager.moveItem(at: packageDirectory, to: finalDirectory)
            let status = try runtime.restoreNeuralImprintCache(from: finalDirectory)
            neuralImprintCacheStatus = status
            neuralImprintCacheError = nil
            if movedExistingToBackup {
                try? fileManager.removeItem(at: backupDirectory)
            }
            writeNeuralImprintRestoreReceipt(
                status: status,
                outcome: "halo_capsule_restored",
                error: nil
            )
            return status
        } catch {
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(at: finalDirectory, to: failedDirectory)
            }
            if movedExistingToBackup,
               fileManager.fileExists(atPath: backupDirectory.path),
               !fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
                if let restored = try? runtime.restoreNeuralImprintCache(from: finalDirectory) {
                    neuralImprintCacheStatus = restored
                    neuralImprintCacheError = nil
                }
            }
            if fileManager.fileExists(atPath: packageDirectory.path) {
                try? fileManager.removeItem(at: packageDirectory)
            }
            neuralImprintCacheError = error.localizedDescription
            writeNeuralImprintRestoreReceipt(
                status: nil,
                outcome: "halo_capsule_restore_failed",
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func restorePersonalizationStateAfterModelLoad() async {
        guard isNeuralImprintRestoreEnabled else {
            neuralImprintCacheStatus = nil
            neuralImprintCacheError = nil
            writeNeuralImprintRestoreReceipt(status: nil, outcome: "disabled_by_user_setting", error: nil)
            NSLog("[AIManager] Neural Imprint restore skipped by user setting")
            return
        }
        _ = await restoreNeuralImprintCacheIfAvailable()
    }

    func runRPPProfileAnalysis(
        sentences: [String],
        rawTransactions: [HaloRPPRawTransaction],
        directionsAURL: URL,
        aLibraryManifestURL: URL,
        targetLayer: Int = 23,
        directionSetID: String = "directions_a",
        nComponents: Int = 5,
        topK: Int = 5,
        profileContext: HaloRPPProfileContext = .finance,
        progress: @escaping @Sendable (HaloRPPProgress) -> Void
    ) async throws -> HaloRPPOutput {
        let modelID = loadedModelName
            ?? lastLoadedDirectory?.lastPathComponent
            ?? ScaffoldConfig.modelID
        return try await edgeHalo.runProfileAnalysis(
            sentences: sentences,
            rawTransactions: rawTransactions,
            directionsAURL: directionsAURL,
            aLibraryManifestURL: aLibraryManifestURL,
            aLibraryRequirements: RPPALibraryRuntimeRequirements(
                modelFamily: ScaffoldConfig.rppModelFamily,
                hiddenSize: ScaffoldConfig.rppHiddenSize,
                layerCount: ScaffoldConfig.rppLayerCount,
                targetLayer: targetLayer,
                directionSetID: directionSetID
            ),
            targetLayer: targetLayer,
            nComponents: nComponents,
            topK: topK,
            modelID: modelID,
            profileContext: profileContext,
            progress: progress
        )
    }

    static func firstAvailableNeuralImprintDirectory() -> URL? {
        return neuralImprintCandidateDirectories().first { directory in
            neuralImprintDirectoryContainsArtifact(directory)
        }
    }

    static func neuralImprintCandidateDirectories() -> [URL] {
        let docs = documentsDirectory
        return [
            docs.appendingPathComponent("neural_imprint", isDirectory: true),
            docs.appendingPathComponent("halo", isDirectory: true)
                .appendingPathComponent("neural_imprint", isDirectory: true),
            docs.appendingPathComponent("halo_capsule", isDirectory: true)
                .appendingPathComponent("neural_imprint", isDirectory: true),
            docs.appendingPathComponent("HaloCapsule", isDirectory: true)
                .appendingPathComponent("neural_imprint", isDirectory: true),
        ]
    }

    static func neuralImprintDirectoryContainsArtifact(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent(LLMEngine.neuralImprintArtifactFileName).path
        ) && fileManager.fileExists(
            atPath: directory.appendingPathComponent(LLMEngine.neuralImprintMetadataFileName).path
        )
    }

    static var neuralImprintCacheBackendVersion: String {
        "edge-engine \(EdgeKitRuntime.nativeRuntimeVersion)"
    }

    private static var neuralImprintReadOnlyToolNames: Set<String> {
        Set(ScaffoldSampleDomainRegistry.selectedToolNames())
    }

    static func neuralImprintToolMetadata() -> [ToolMetadata] {
        EdgeInference.ToolRegistry.shared
            .allSchemas()
            .filter { $0.isReadOnly && neuralImprintReadOnlyToolNames.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    static func neuralImprintToolSchemaSnapshot() throws -> ToolSchemaSnapshot {
        let toolMetadata = neuralImprintToolMetadata()
        guard !toolMetadata.isEmpty else {
            throw EdgeRuntimeError.unsupportedFeature(
                "Neural Imprint capture requires at least one read-only tool schema"
            )
        }
        return try EdgeInference.ToolRegistry.shared.toolSchemaSnapshot(
            forNames: toolMetadata.map(\.name)
        )
    }

    static let toolsOnlyNeuralImprintProfileBody = ""

    private static func installNeuralImprintBuildDirectory(
        _ buildDirectory: URL,
        replacing finalDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let backupDirectory = documentsDirectory.appendingPathComponent(
            "neural_imprint.previous-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedExistingToBackup = false
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.moveItem(at: finalDirectory, to: backupDirectory)
            movedExistingToBackup = true
        }
        do {
            try fileManager.moveItem(at: buildDirectory, to: finalDirectory)
            if movedExistingToBackup {
                try? fileManager.removeItem(at: backupDirectory)
            }
        } catch {
            if movedExistingToBackup,
               fileManager.fileExists(atPath: backupDirectory.path),
               !fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
            }
            throw error
        }
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func referencedWeightFiles(in indexURL: URL, under directory: URL) -> [URL] {
        guard let data = try? Data(contentsOf: indexURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = object["weight_map"] as? [String: String] else {
            return []
        }
        return Set(weightMap.values).sorted().map {
            directory.appendingPathComponent($0)
        }
    }

    private func writeNeuralImprintRestoreReceipt(
        status: NeuralImprintRuntimeCacheStatus?,
        outcome: String,
        error: String?
    ) {
        let receiptURL = Self.documentsDirectory.appendingPathComponent("neural_imprint_restore_status.json")
        let docs = Self.documentsDirectory.standardizedFileURL
        func relativePath(_ url: URL?) -> String? {
            guard let url else { return nil }
            let path = url.standardizedFileURL.path
            let docsPath = docs.path
            if path == docsPath {
                return "Documents"
            }
            if path.hasPrefix(docsPath + "/") {
                return "Documents/" + String(path.dropFirst(docsPath.count + 1))
            }
            return url.lastPathComponent
        }

        var payload: [String: Any] = [
            "schema": "edgestudio.scaffold.neural_imprint_restore_status.v2",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome,
            "scaffold_model_id": ScaffoldConfig.modelID,
        ]
        if let status {
            payload["model_id"] = status.modelID
            payload["directory"] = relativePath(status.directory)
            payload["artifact"] = relativePath(status.artifactURL)
            payload["metadata"] = relativePath(status.metadataURL)
            payload["artifact_sha256"] = status.artifactSHA256
            payload["prefix_token_count"] = status.prefixTokenCount
            payload["enable_thinking"] = status.enableThinking
            payload["cache_backend"] = status.cacheBackend
            payload["cache_backend_version"] = status.cacheBackendVersion
        }
        if let error {
            payload["error"] = error
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: receiptURL, options: [.atomic])
        } catch {
            NSLog("[AIManager] failed to write Neural Imprint restore receipt: \(error)")
        }
    }


    func unloadModel() {
        switch modelCategory {
        case .llm: llmEngine?.unload()
        case .vlm: vlmEngine?.unload()
        case .tts: ttsEngine?.unload()
        case .stt: break // STT 无 unload 方法
        }
        isModelLoaded = false
        loadSource = .none
        neuralImprintCacheStatus = nil
        neuralImprintCacheError = nil
    }

    func handleBackgrounding() {
        unloadModel()
    }

    func handleForegrounding() async {
        guard stateManager.isAIEnabled,
              !isModelLoaded else { return }
        guard stateManager.isModelDownloaded || Self.isDocumentsModelAvailable() else { return }
        await loadSelectedModel()
    }
}


extension AIManager: EdgeGenerationClient {
    var currentInferenceMetrics: InferenceMetrics? {
        switch modelCategory {
        case .llm: return llmEngine?.lastMetrics
        case .vlm: return vlmEngine?.lastMetrics
        case .tts, .stt: return nil
        }
    }

    func generate(
        messages: [ChatMessage],
        ciImages: [CIImage],
        tools: [EdgeSessionToolSpec]?,
        onToolCall: (@Sendable (ToolCall) async throws -> String)?,
        parameters: EdgeGenerateParameters?,
        onChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let stream = generate(
            messages: messages,
            ciImages: ciImages,
            tools: tools,
            onToolCall: onToolCall,
            parameters: parameters
        )
        var output = ""
        for try await chunk in stream {
            output += chunk
            onChunk(chunk)
        }
        return output
    }

    func resetRuntime(reason: String) async {
        resetChatRuntime(reason: reason)
    }

    func resetChatRuntime(reason: String) {
        switch modelCategory {
        case .llm:
            llmEngine?.clearPromptCache()
        case .vlm:
            vlmEngine?.promptCache.clear()
        case .tts, .stt:
            break
        }
        NSLog("[AIManager] chat runtime reset reason=\(reason)")
    }
}
