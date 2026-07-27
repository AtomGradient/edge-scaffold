// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Darwin
import CryptoKit
import Foundation
import EdgeInference
import EdgeSession

@MainActor
enum ScaffoldDomainABSmokeRunner {
    static let launchArgument = "--scaffold-domain-ab-smoke"
    static let domainArgumentPrefix = "--scaffold-domain-ab-smoke-domain="
    static let resultFileName = "scaffold_domain_ab_smoke_result.json"
    private static let generationWatchdog = EdgeGenerationWatchdog.Configuration(
        enabled: true,
        turnTimeoutSeconds: 300,
        livenessTimeoutSeconds: 120,
        heartbeatIntervalSeconds: 10
    )
    private static let baseControlWatchdog = EdgeGenerationWatchdog.Configuration(
        enabled: true,
        turnTimeoutSeconds: 90,
        livenessTimeoutSeconds: 45,
        heartbeatIntervalSeconds: 10
    )
    private static let includeBaselineEnvironmentKey =
        "EDGE_SCAFFOLD_AB_INCLUDE_BASELINE"
    private static let controlledV2EnvironmentKey =
        "EDGE_SCAFFOLD_AB_CONTROLLED_V2"
    private static let controlledV2RepeatsEnvironmentKey =
        "EDGE_SCAFFOLD_AB_CONTROLLED_V2_REPEATS"
    private static let controlledV2MaxTokens = 128
    private static let controlledV2MaxRounds = 3

    private static var includeBaseline: Bool {
        let raw = ProcessInfo.processInfo.environment[includeBaselineEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static var controlledV2: Bool {
        let raw = ProcessInfo.processInfo.environment[controlledV2EnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static var controlledV2Repeats: Int {
        let raw = ProcessInfo.processInfo.environment[controlledV2RepeatsEnvironmentKey] ?? "3"
        return min(10, max(1, Int(raw) ?? 3))
    }

    private static var reportSchemaVersion: String {
        controlledV2
            ? "edge_scaffold.domain_neural_imprint_controlled.v2"
            : "edge_scaffold.domain_neural_imprint_ab_smoke.v1"
    }

    static var shouldRun: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func runAndExit() {
        Task { @MainActor in
            let report = await run()
            do {
                try write(report)
            } catch {
                NSLog("[ScaffoldDomainABSmokeRunner] failed to write report: \(error.localizedDescription)")
            }
            NSLog("[ScaffoldDomainABSmokeRunner] completed passed=\(report.passed) domains=\(report.results.count)")
            Darwin.exit(report.passed ? 0 : 1)
        }
    }

    private static func run() async -> DomainABSmokeReport {
        let startedAt = Date()
        let aiManager = AIManager.shared
        var topLevelErrors: [String] = []
        let originalRestoreEnabled = aiManager.isNeuralImprintRestoreEnabled
        let selectedDomains = selectedDomains()
        writeCheckpoint(startedAt: startedAt, topLevelErrors: [], results: [])

        aiManager.setNeuralImprintRestoreEnabled(false, reloadIfLoaded: false)
        deactivateNeuralImprint(aiManager)

        do {
            try await ensureModelLoaded(aiManager)
            logDiagnostic("initial_model_ready", aiManager: aiManager)
        } catch {
            topLevelErrors.append(error.localizedDescription)
            logDiagnostic("initial_model_load_failed", aiManager: aiManager)
        }

        var results: [DomainABResult] = []
        if topLevelErrors.isEmpty {
            for domain in selectedDomains {
                NSLog("[ScaffoldDomainABSmokeRunner] domain start id=\(domain.id.rawValue)")
                let result = await smoke(
                    domain: domain,
                    aiManager: aiManager,
                    startedAt: startedAt,
                    topLevelErrors: topLevelErrors,
                    completedResults: results
                )
                results.append(result)
                NSLog("[ScaffoldDomainABSmokeRunner] domain finished id=\(domain.id.rawValue) passed=\(result.passed)")
                writeCheckpoint(startedAt: startedAt, topLevelErrors: topLevelErrors, results: results)
            }
        }

        aiManager.isNeuralImprintRestoreEnabled = originalRestoreEnabled
        let finishedAt = Date()
        return DomainABSmokeReport(
            schemaVersion: reportSchemaVersion,
            startedAt: isoString(from: startedAt),
            finishedAt: isoString(from: finishedAt),
            durationMs: Int(finishedAt.timeIntervalSince(startedAt) * 1_000),
            passed: topLevelErrors.isEmpty && results.allSatisfy(\.passed),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            runtimeMetadata: runtimeMetadata(),
            modelID: ScaffoldConfig.modelID,
            topLevelErrors: topLevelErrors,
            results: results
        )
    }

    private static func ensureModelLoaded(_ aiManager: AIManager) async throws {
        guard ScaffoldConfig.modelCategory == .llm else {
            throw ABRunnerError.unsupportedRuntime(ScaffoldConfig.modelCategory.rawValue)
        }
        if aiManager.isModelLoaded, aiManager.llmEngine?.state == .ready {
            return
        }
        let diagnostic = AIManager.validateDocumentsModelInstall()
        guard diagnostic.status == .valid else {
            throw ABRunnerError.modelUnavailable(diagnostic.message)
        }
        await aiManager.loadSelectedModel()
        guard aiManager.isModelLoaded, aiManager.llmEngine?.state == .ready else {
            throw ABRunnerError.modelLoadFailed(aiManager.loadError ?? "unknown")
        }
    }

    private static func smoke(
        domain: ScaffoldSampleDomainDescriptor,
        aiManager: AIManager,
        startedAt: Date,
        topLevelErrors: [String],
        completedResults: [DomainABResult]
    ) async -> DomainABResult {
        let domainStartedAt = Date()
        var errors: [String] = []
        let expectedRecords = (try? domain.loadRecordCount()) ?? 0
        var seedStats: DomainABSeedStats?
        var rpp: DomainABRPPResult?
        let prompts = promptPair(for: domain)
        var promptResults = prompts.map { prompt in
            DomainABPromptResult(
                kind: prompt.kind,
                prompt: prompt.text,
                expectedToolName: prompt.expectedToolName,
                acceptedToolNames: acceptedToolNames(for: prompt, domain: domain),
                expectedAnswerContainsAny: prompt.expectedAnswerContainsAny,
                baseAnswer: "",
                imprintAnswer: "",
                imprintActive: false,
                prefixTokens: 0,
                toolCallsBase: [],
                toolCallsImprint: [],
                toolTrace: [],
                controlledArms: [],
                deltaSummary: "",
                elapsedBaseMs: 0,
                elapsedImprintMs: 0,
                baseFirstChunkMs: nil,
                imprintFirstChunkMs: nil,
                baseTTFTMs: nil,
                imprintTTFTMs: nil,
                baseGeneratedTokens: nil,
                imprintGeneratedTokens: nil,
                baseTimedOut: false,
                imprintTimedOut: false,
                errors: []
            )
        }

        func checkpoint() {
            let partial = makeDomainResult(
                domain: domain,
                expectedRecords: expectedRecords,
                seedStats: seedStats,
                rpp: rpp,
                prompts: promptResults,
                domainStartedAt: domainStartedAt,
                errors: errors,
                final: false
            )
            writeCheckpoint(
                startedAt: startedAt,
                topLevelErrors: topLevelErrors,
                results: completedResults + [partial]
            )
        }

        do {
            let stats = try await seedAndLoadStats(domain: domain)
            seedStats = DomainABSeedStats(stats)
            if stats.sampleRecords != expectedRecords {
                errors.append("sampleRecords \(stats.sampleRecords) != expected \(expectedRecords)")
            }
            if stats.classified != expectedRecords {
                errors.append("classified \(stats.classified) != expected \(expectedRecords)")
            }
            checkpoint()
        } catch {
            errors.append("seed/stats failed: \(error.localizedDescription)")
            let result = makeDomainResult(
                domain: domain,
                expectedRecords: expectedRecords,
                seedStats: seedStats,
                rpp: rpp,
                prompts: promptResults,
                domainStartedAt: domainStartedAt,
                errors: errors,
                final: true
            )
            checkpoint()
            return result
        }

        deactivateNeuralImprint(aiManager)
        let smokeSession = ChatSessionController(client: aiManager)
        await resetSmokeSession(
            smokeSession,
            aiManager: aiManager,
            reason: "domain_ab_smoke_domain_start"
        )

        if includeBaseline {
            deactivateNeuralImprint(aiManager)
            for index in promptResults.indices {
                await resetSmokeSession(
                    smokeSession,
                    aiManager: aiManager,
                    reason: "smoke_base_\(index)"
                )
                NSLog("[ScaffoldDomainABSmokeRunner] base prompt domain=\(domain.id.rawValue) kind=\(promptResults[index].kind)")
                logDiagnostic(
                    "base_prompt_begin kind=\(promptResults[index].kind)",
                    domain: domain,
                    aiManager: aiManager
                )
                let base = await generateBaseAnswer(
                    prompt: promptResults[index].prompt,
                    aiManager: aiManager,
                    session: smokeSession
                )
                logDiagnostic(
                    "base_prompt_end kind=\(promptResults[index].kind) timedOut=\(base.timedOut) elapsedMs=\(base.elapsedMs)",
                    domain: domain,
                    aiManager: aiManager
                )
                promptResults[index].baseAnswer = base.answer
                promptResults[index].toolCallsBase = base.toolCalls
                promptResults[index].elapsedBaseMs = base.elapsedMs
                promptResults[index].baseFirstChunkMs = base.firstChunkMs
                promptResults[index].baseTTFTMs = base.ttftMs
                promptResults[index].baseGeneratedTokens = base.generatedTokens
                promptResults[index].baseTimedOut = base.timedOut
                promptResults[index].errors.append(contentsOf: base.errors.map { "base: \($0)" })
                checkpoint()
                if base.timedOut {
                    errors.append("base prompt timed out")
                    break
                }
            }
        }

        do {
            await resetSmokeSession(
                smokeSession,
                aiManager: aiManager,
                reason: "pre_rpp_clean"
            )
            aiManager.resetChatRuntime(reason: "pre_rpp_clean")
            NSLog("[ScaffoldDomainABSmokeRunner] rpp start domain=\(domain.id.rawValue)")
            logDiagnostic("rpp_before_start", domain: domain, aiManager: aiManager)
            let rppResult = try await runRPP(aiManager: aiManager)
            logDiagnostic("rpp_after_finish", domain: domain, aiManager: aiManager)
            rpp = rppResult
            if rppResult.directionSetID != domain.rppDirectionSetID {
                errors.append("rpp selected direction_set_id=\(rppResult.directionSetID ?? "nil"), expected \(domain.rppDirectionSetID)")
            }
            if rppResult.usedFallback != false {
                errors.append("rpp used fallback A-library")
            }
            if rppResult.aHealthVerdict != "pass" {
                errors.append("rpp A-library health_verdict=\(rppResult.aHealthVerdict ?? "nil"), expected pass")
            }
            if rppResult.prefixTokens <= 0 {
                errors.append("Neural Imprint prefix tokens not active")
            }
            NSLog("[ScaffoldDomainABSmokeRunner] rpp finished domain=\(domain.id.rawValue) prefix=\(rppResult.prefixTokens)")
            smokeSession.replaceHistory([], mode: .isolated("smoke_imprint"))
            checkpoint()
        } catch {
            errors.append("rpp/neural imprint failed: \(error.localizedDescription)")
            NSLog("[ScaffoldDomainABSmokeRunner] rpp failed domain=\(domain.id.rawValue) error=\(error.localizedDescription)")
            logDiagnostic("rpp_failed", domain: domain, aiManager: aiManager)
            checkpoint()
        }

        if controlledV2 {
            if errors.contains(where: { $0.hasPrefix("rpp/neural imprint failed") }) {
                return makeDomainResult(
                    domain: domain,
                    expectedRecords: expectedRecords,
                    seedStats: seedStats,
                    rpp: rpp,
                    prompts: promptResults,
                    domainStartedAt: domainStartedAt,
                    errors: errors,
                    final: true
                )
            }
            let controlled = await runControlledV2(
                domain: domain,
                prompts: promptResults,
                aiManager: aiManager
            )
            promptResults = controlled.prompts
            errors.append(contentsOf: controlled.errors)
            return makeDomainResult(
                domain: domain,
                expectedRecords: expectedRecords,
                seedStats: seedStats,
                rpp: rpp,
                prompts: promptResults,
                domainStartedAt: domainStartedAt,
                errors: errors,
                final: true
            )
        }

        for index in promptResults.indices {
            var result = promptResults[index]
            if errors.contains(where: { $0.hasPrefix("rpp/neural imprint failed") }) {
                result.errors.append("skipped imprint generation because Neural Imprint is inactive")
                promptResults[index] = result
                continue
            }
            NSLog("[ScaffoldDomainABSmokeRunner] imprint prompt domain=\(domain.id.rawValue) kind=\(result.kind)")
            let imprint = if result.kind == "fact" {
                await generateImprintFactAnswer(
                    prompt: result.prompt,
                    aiManager: aiManager,
                    session: smokeSession
                )
            } else {
                await generateImprintProfileAnswer(
                    prompt: result.prompt,
                    aiManager: aiManager,
                    session: smokeSession
                )
            }
            result.imprintAnswer = imprint.answer
            result.imprintActive = aiManager.hasNeuralImprintCache
            result.prefixTokens = aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0
            result.toolCallsImprint = imprint.toolCalls
            result.toolTrace = imprint.toolTrace
            result.elapsedImprintMs = imprint.elapsedMs
            result.imprintFirstChunkMs = imprint.firstChunkMs
            result.imprintTTFTMs = imprint.ttftMs
            result.imprintGeneratedTokens = imprint.generatedTokens
            result.imprintTimedOut = imprint.timedOut
            result.errors.append(contentsOf: imprint.errors.map { "imprint: \($0)" })
            if result.kind == "fact",
               !result.acceptedToolNames.isEmpty,
               !imprint.toolCalls.contains(where: { result.acceptedToolNames.contains($0) }) {
                result.errors.append("imprint: expected one of domain tool calls \(result.acceptedToolNames.joined(separator: ","))")
            }
            if result.kind == "fact", !toolTraceHasNonEmptyResult(imprint.toolTrace) {
                result.errors.append("imprint: fact tool call returned no matching rows")
            }
            if !result.expectedAnswerContainsAny.isEmpty,
               !answer(result.imprintAnswer, containsAny: result.expectedAnswerContainsAny) {
                result.errors.append("imprint: answer did not contain expected marker \(result.expectedAnswerContainsAny.joined(separator: "/"))")
            }
            promptResults[index] = result
            checkpoint()
            if imprint.timedOut {
                errors.append("imprint prompt timed out; aborting domain to avoid overlapping GPU generation")
                let result = makeDomainResult(
                    domain: domain,
                    expectedRecords: expectedRecords,
                    seedStats: seedStats,
                    rpp: rpp,
                    prompts: promptResults,
                    domainStartedAt: domainStartedAt,
                    errors: errors,
                    final: true
                )
                checkpoint()
                return result
            }
        }

        for prompt in promptResults {
            let blockingErrors = prompt.errors.filter { !$0.hasPrefix("base:") }
            if !blockingErrors.isEmpty {
                errors.append("prompt '\(prompt.prompt)' errors: \(blockingErrors.joined(separator: "; "))")
            }
        }

        return makeDomainResult(
            domain: domain,
            expectedRecords: expectedRecords,
            seedStats: seedStats,
            rpp: rpp,
            prompts: promptResults,
            domainStartedAt: domainStartedAt,
            errors: errors,
            final: true
        )
    }

    private static func runControlledV2(
        domain: ScaffoldSampleDomainDescriptor,
        prompts: [DomainABPromptResult],
        aiManager: AIManager
    ) async -> ControlledRunResult {
        var updatedPrompts = prompts.filter { $0.kind != "general" }
        var errors: [String] = []
        NSLog(
            "[ScaffoldDomainABSmokeRunner] controlled v2 start domain=%@ prompts=%d repeats=%d",
            domain.id.rawValue,
            updatedPrompts.count,
            controlledV2Repeats
        )
        guard let artifactDirectory = aiManager.neuralImprintCacheStatus?.directory else {
            return ControlledRunResult(
                prompts: updatedPrompts,
                errors: ["controlled_v2: active artifact directory unavailable after RPP"]
            )
        }
        let profileURL = artifactDirectory.appendingPathComponent("profile_body.txt")
        let metadataURL = artifactDirectory.appendingPathComponent("neural_imprint_metadata.json")
        guard let profileBody = try? String(contentsOf: profileURL, encoding: .utf8),
              !profileBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ControlledRunResult(
                prompts: updatedPrompts,
                errors: ["controlled_v2: neural_imprint/profile_body.txt missing or empty"]
            )
        }

        let sidecar = readJSONObject(at: metadataURL)
        let sidecarSource = sidecar?["source"] as? [String: Any]
        let sidecarPrefix = sidecar?["prefix"] as? [String: Any]
        let artifactProfileBodySHA256 = sidecarSource?["profile_body_sha256"] as? String
        let artifactPrefixTokenIDsSHA256 = sidecarPrefix?["token_ids_sha256"] as? String
        let toolSchemaSHA256 = sidecarSource?["tool_schema_sha256"] as? String
        let profileBodySHA256 = sha256Text(profileBody)
        if artifactProfileBodySHA256 != profileBodySHA256 {
            errors.append(
                "controlled_v2: profile body hash mismatch artifact=\(artifactProfileBodySHA256 ?? "nil") actual=\(profileBodySHA256)"
            )
        }

        let toolNames = ScaffoldSampleDomainRegistry.selectedToolNames()
        let toolSpecs: [EdgeSessionToolSpec]
        do {
            toolSpecs = try ToolRegistry.shared.toolSpecs(forNames: toolNames)
        } catch {
            return ControlledRunResult(
                prompts: updatedPrompts,
                errors: errors + ["controlled_v2: tool specs unavailable: \(error.localizedDescription)"]
            )
        }

        var parameters = controlledV2Parameters()
        let visibleToolsPrefix: NeuralImprintPrefixRender
        do {
            guard let engine = aiManager.llmEngine else {
                throw ABRunnerError.modelLoadFailed("LLM engine missing")
            }
            visibleToolsPrefix = try await engine.renderNeuralImprintPrefix(
                profileBody: profileBody,
                tools: toolSpecs,
                parameters: parameters
            )
        } catch {
            return ControlledRunResult(
                prompts: updatedPrompts,
                errors: errors + ["controlled_v2: exact prefix render failed: \(error.localizedDescription)"]
            )
        }
        let visibleToolsPrefixSHA256 = tokenIDsSHA256(visibleToolsPrefix.prefixTokenIDs)
        let prefixTokenHashMatched =
            artifactPrefixTokenIDsSHA256 == visibleToolsPrefixSHA256
        if !prefixTokenHashMatched {
            errors.append(
                "controlled_v2: live/restored prefix token hash mismatch artifact=\(artifactPrefixTokenIDsSHA256 ?? "nil") live=\(visibleToolsPrefixSHA256)"
            )
        }
        if visibleToolsPrefix.prefixTokenIDs.count
            != aiManager.neuralImprintCacheStatus?.prefixTokenCount {
            errors.append(
                "controlled_v2: live/restored prefix token count mismatch live=\(visibleToolsPrefix.prefixTokenIDs.count) restored=\(aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0)"
            )
        }

        let arms = ControlledArm.allCases
        var executionSequence = 0
        for repeatIndex in 0..<controlledV2Repeats {
            for promptIndex in updatedPrompts.indices {
                let offset = (repeatIndex + promptIndex) % arms.count
                let orderedArms = Array(arms[offset...]) + Array(arms[..<offset])
                for arm in orderedArms {
                    executionSequence += 1
                    if arm == .imprint {
                        let restored = await aiManager.restoreNeuralImprintCacheIfAvailable()
                        if !restored {
                            errors.append(
                                "controlled_v2: restore failed prompt=\(updatedPrompts[promptIndex].kind) repeat=\(repeatIndex)"
                            )
                        }
                    } else {
                        deactivateNeuralImprint(aiManager)
                    }
                    await Task.yield()

                    let session = ChatSessionController(client: aiManager)
                    parameters = controlledV2Parameters()
                    let generation = await generateControlledAnswer(
                        arm: arm,
                        prompt: updatedPrompts[promptIndex].prompt,
                        profileBody: profileBody,
                        toolNames: toolNames,
                        toolSpecs: toolSpecs,
                        parameters: parameters,
                        aiManager: aiManager,
                        session: session
                    )
                    let livePrefixSHA256: String?
                    if arm == .imprint {
                        livePrefixSHA256 = visibleToolsPrefixSHA256
                    } else {
                        let systemPrompt = arm.profileInContext
                            ? profileBody
                            : ScaffoldConfig.defaultSystemPrompt
                        let prefixTools = arm.toolsInContext ? toolSpecs : []
                        if let engine = aiManager.llmEngine,
                           let render = try? await engine.renderNeuralImprintPrefix(
                            profileBody: systemPrompt,
                            tools: prefixTools,
                            parameters: parameters
                           ) {
                            livePrefixSHA256 = tokenIDsSHA256(render.prefixTokenIDs)
                        } else {
                            livePrefixSHA256 = nil
                        }
                    }
                    let metrics = generation.metrics
                    let armErrors = generation.errors
                    updatedPrompts[promptIndex].controlledArms.append(
                        DomainABControlledArmResult(
                            arm: arm.rawValue,
                            repeatIndex: repeatIndex,
                            executionSequence: executionSequence,
                            profileInContext: arm.profileInContext,
                            prefixDelivery: arm.prefixDelivery,
                            toolsInContext: arm.toolsInContext,
                            answer: generation.answer,
                            neuralImprintActive: aiManager.hasNeuralImprintCache,
                            prefixTokens: aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0,
                            profileBodySHA256: arm.profileInContext ? profileBodySHA256 : nil,
                            prefixTokenIDsSHA256: livePrefixSHA256,
                            artifactPrefixTokenIDsSHA256: artifactPrefixTokenIDsSHA256,
                            prefixTokenHashMatched: arm == .visibleProfileToolsLive || arm == .imprint
                                ? prefixTokenHashMatched
                                : nil,
                            systemPromptSHA256: sha256Text(
                                arm.profileInContext
                                    ? profileBody
                                    : ScaffoldConfig.defaultSystemPrompt
                            ),
                            toolSchemaSHA256: arm.toolsInContext ? toolSchemaSHA256 : nil,
                            toolCalls: generation.toolCalls,
                            toolTrace: generation.toolTrace,
                            elapsedMs: generation.elapsedMs,
                            firstChunkMs: generation.firstChunkMs,
                            ttftMs: metrics?.ttftMs,
                            decodeTPS: metrics?.decodeTPS,
                            promptTokenCount: metrics?.promptTokenCount,
                            prefillTokenCount: metrics?.phaseTimings?.prefillTokenCount,
                            prefillMs: metrics?.phaseTimings?.prefillMs,
                            prefillMode: metrics?.phaseTimings?.prefillMode,
                            generatedTokens: metrics?.generationTokenCount,
                            promptCacheHit: metrics?.promptCacheHit,
                            cachedTokensReused: metrics?.cachedTokensReused,
                            thermalState: metrics?.thermalState,
                            memoryBeforeMB: metrics?.memoryBeforeMB,
                            memoryAfterMB: metrics?.memoryAfterMB,
                            policyReasoning: metrics?.policyReasoning,
                            maxTokens: parameters.maxTokens,
                            maxRounds: arm.toolsInContext ? controlledV2MaxRounds : 0,
                            turnTimeoutSeconds: generationWatchdog.turnTimeoutSeconds,
                            livenessTimeoutSeconds: generationWatchdog.livenessTimeoutSeconds,
                            enableThinking: parameters.enableThinking,
                            preserveThinking: parameters.preserveThinking,
                            useDSR: parameters.useDSR,
                            kvBits: parameters.kvBits,
                            maxKVSize: parameters.maxKVSize,
                            prefillStepSize: parameters.prefillStepSize,
                            frogJumpEnabled: parameters.frogJumpEnabled,
                            timedOut: generation.timedOut,
                            errors: armErrors
                        )
                    )
                }
            }
        }
        return ControlledRunResult(prompts: updatedPrompts, errors: errors)
    }

    private static func controlledV2Parameters() -> EdgeGenerateParameters {
        var parameters = AIManager.defaultParameters(enableThinking: false)
        applySmokeGenerationPolicy(&parameters, maxTokens: controlledV2MaxTokens)
        parameters.preserveThinking = false
        parameters.useDSR = false
        parameters.dsrMaxCritical = nil
        parameters.dsrHeavyBudget = nil
        parameters.dsrRecentBudget = nil
        parameters.dsrEvictionInterval = 0
        parameters.kvBits = nil
        parameters.quantizedKVStart = 0
        parameters.maxKVSize = nil
        parameters.frogJumpEnabled = false
        return parameters
    }

    private static func generateControlledAnswer(
        arm: ControlledArm,
        prompt: String,
        profileBody: String,
        toolNames: [String],
        toolSpecs: [EdgeSessionToolSpec],
        parameters: EdgeGenerateParameters,
        aiManager: AIManager,
        session: ChatSessionController
    ) async -> ControlledGeneration {
        let startedAt = Date()
        var firstChunkMs: Int?
        var toolCalls: [String] = []
        var toolTrace: [DomainABToolTrace] = []
        var pendingToolArguments: [String: [String]] = [:]
        let messages: [ChatMessage] = if arm == .imprint {
            [.user(prompt)]
        } else {
            [
                .system(
                    arm.profileInContext
                        ? profileBody
                        : ScaffoldConfig.defaultSystemPrompt
                ),
                .user(prompt),
            ]
        }

        do {
            try await ensureModelLoaded(aiManager)
            let answer: String
            if arm.toolsInContext {
                answer = try await ToolChatLoop.run(
                    session: session,
                    request: ToolChatLoop.Request(
                        messages: messages,
                        mode: .isolated("controlled_v2_\(arm.rawValue)"),
                        tools: toolSpecs,
                        allowedToolNames: toolNames,
                        maxRounds: controlledV2MaxRounds,
                        parameters: parameters,
                        timeoutSeconds: nil,
                        watchdogConfiguration: generationWatchdog,
                        emptyFinalText: ""
                    ),
                    hooks: ToolChatLoop.Hooks(
                        executePlannedTool: { plan in
                            try await ToolRegistry.shared.execute(plan)
                        },
                        executeModelTool: { toolCall in
                            try await ToolRegistry.shared.execute(toolCall)
                        },
                        summarizeToolResults: { _ in "" },
                        streamSummary: { _, _ in },
                        onModelToolCall: { toolCall in
                            let name = toolCall.function.name
                            toolCalls.append(name)
                            pendingToolArguments[name, default: []].append(
                                argumentsText(toolCall.function.arguments)
                            )
                        },
                        onToolResult: { result in
                            let arguments: String
                            if var queued = pendingToolArguments[result.name], !queued.isEmpty {
                                arguments = queued.removeFirst()
                                pendingToolArguments[result.name] = queued
                            } else {
                                arguments = ""
                            }
                            toolTrace.append(DomainABToolTrace(
                                name: result.name,
                                source: result.source,
                                argumentsPrefix: String(arguments.prefix(300)),
                                matchedCount: toolResultInt(
                                    result.result,
                                    keys: ["matched_count", "matchedCount"]
                                ),
                                totalClassified: toolResultInt(
                                    result.result,
                                    keys: ["total_classified", "totalClassified"]
                                ),
                                totalAmount: toolResultDouble(
                                    result.result,
                                    keys: ["total_amount", "totalAmount"]
                                ),
                                totalDurationMinutes: toolResultDouble(
                                    result.result,
                                    keys: ["total_duration_minutes", "totalDurationMinutes"]
                                ),
                                resultPrefix: String(result.result.prefix(300))
                            ))
                        }
                    )
                ) { chunk in
                    if firstChunkMs == nil, !chunk.isEmpty {
                        firstChunkMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    }
                }
            } else {
                answer = try await session.generatePrepared(
                    messages: messages,
                    mode: .isolated("controlled_v2_\(arm.rawValue)"),
                    parameters: parameters,
                    timeoutSeconds: nil,
                    watchdogConfiguration: generationWatchdog
                ) { chunk in
                    if firstChunkMs == nil, !chunk.isEmpty {
                        firstChunkMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    }
                }
            }
            return ControlledGeneration(
                answer: answer,
                toolCalls: toolCalls,
                toolTrace: toolTrace,
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: firstChunkMs,
                metrics: session.lastMetrics,
                timedOut: false,
                errors: []
            )
        } catch {
            return ControlledGeneration(
                answer: "",
                toolCalls: toolCalls,
                toolTrace: toolTrace,
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: firstChunkMs,
                metrics: session.lastMetrics,
                timedOut: isTimeout(error),
                errors: [error.localizedDescription]
            )
        }
    }

    private static func sha256Text(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func tokenIDsSHA256(_ tokenIDs: [Int]) -> String {
        sha256Text("[\(tokenIDs.map(String.init).joined(separator: ","))]")
    }

    private static func makeDomainResult(
        domain: ScaffoldSampleDomainDescriptor,
        expectedRecords: Int,
        seedStats: DomainABSeedStats?,
        rpp: DomainABRPPResult?,
        prompts: [DomainABPromptResult],
        domainStartedAt: Date,
        errors: [String],
        final: Bool
    ) -> DomainABResult {
        let promptGate = if controlledV2 {
            prompts.allSatisfy { prompt in
                prompt.controlledArms.count == 5 * controlledV2Repeats
                    && prompt.controlledArms.allSatisfy {
                        !$0.answer.isEmpty
                            && $0.errors.isEmpty
                            && !$0.timedOut
                            && ($0.arm != ControlledArm.imprint.rawValue
                                || $0.neuralImprintActive)
                            && ($0.arm == ControlledArm.imprint.rawValue
                                || !$0.neuralImprintActive)
                            && ($0.arm != ControlledArm.visibleProfileToolsLive.rawValue
                                || $0.prefixTokenHashMatched == true)
                    }
            }
        } else {
            prompts.allSatisfy { !$0.imprintAnswer.isEmpty }
        }
        let passed = final
            && errors.isEmpty
            && rpp?.imprintActive == true
            && promptGate

        return DomainABResult(
            domain: domain.id.rawValue,
            displayName: domain.displayName,
            namespace: domain.namespace,
            expectedRecords: expectedRecords,
            seedStats: seedStats,
            rpp: rpp,
            prompts: prompts,
            durationMs: Int(Date().timeIntervalSince(domainStartedAt) * 1_000),
            passed: passed,
            errors: errors
        )
    }

    private static func seedAndLoadStats(
        domain: ScaffoldSampleDomainDescriptor,
        attempts: Int = 4
    ) async throws -> ScaffoldSampleDomainSeedResult {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                _ = try ScaffoldSampleDomainRegistry.switchToDomain(rawValue: domain.id.rawValue)
                _ = try domain.seedClassifiedFacts()
                return try domain.stats()
            } catch {
                lastError = error
                guard attempt < attempts, isTransientDatabaseLock(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
            }
        }
        throw lastError ?? ABRunnerError.seedStatsUnavailable
    }

    private static func runRPP(aiManager: AIManager) async throws -> DomainABRPPResult {
        try await ensureModelLoaded(aiManager)
        logDiagnostic("rpp_manager_reset_before", aiManager: aiManager)
        let manager = RPPSelfLearningManager.shared
        manager.reset()
        manager.start(aiManager: aiManager)

        let waitStarted = Date()
        while !manager.isRunning && manager.lastOutput == nil && manager.lastError == nil {
            if Date().timeIntervalSince(waitStarted) > 10 {
                throw ABRunnerError.rppDidNotStart
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        while manager.isRunning {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if let error = manager.lastError {
            logDiagnostic("rpp_manager_error", aiManager: aiManager)
            throw ABRunnerError.rppFailed(error)
        }
        guard let output = manager.lastOutput else {
            logDiagnostic("rpp_manager_missing_output", aiManager: aiManager)
            throw ABRunnerError.rppMissingOutput
        }
        guard aiManager.hasNeuralImprintCache else {
            logDiagnostic("rpp_manager_imprint_inactive", aiManager: aiManager)
            throw ABRunnerError.imprintInactiveAfterRPP
        }
        logDiagnostic("rpp_manager_output_ready", aiManager: aiManager)
        return DomainABRPPResult(
            datasetSize: manager.datasetSize,
            directionsCount: output.directions.count,
            targetLayer: output.targetLayer,
            totalElapsedSeconds: output.totalElapsedSeconds,
            imprintActive: aiManager.hasNeuralImprintCache,
            prefixTokens: aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0,
            aLibraryID: lastRunString("a_library_id"),
            directionSetID: lastRunString("direction_set_id"),
            aHealthVerdict: lastRunString("a_health_verdict"),
            aHealthReport: lastRunString("a_health_report"),
            aYAMLSHA256: lastRunString("a_yaml_sha256"),
            aSourceType: lastRunString("a_source_type"),
            aSourceSchemaVersion: lastRunString("a_source_schema_version"),
            usedFallback: lastRunBool("used_fallback") ?? lastRunBool("usedFallback")
        )
    }

    private static func generateBaseAnswer(
        prompt: String,
        aiManager: AIManager,
        session: ChatSessionController
    ) async -> GeneratedAnswer {
        let startedAt = Date()
        do {
            try await ensureModelLoaded(aiManager)
            logDiagnostic("generate_base_ready", aiManager: aiManager)
            let plain = try await generatePlain(
                prompt: prompt,
                aiManager: aiManager,
                session: session,
                mode: .isolated("smoke_base"),
                maxTokens: 80,
                watchdogConfiguration: baseControlWatchdog
            )
            return GeneratedAnswer(
                answer: plain.answer,
                toolCalls: toolCallNames(in: plain.answer),
                toolTrace: [],
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: plain.firstChunkMs,
                ttftMs: plain.metrics?.ttftMs,
                generatedTokens: plain.metrics?.generationTokenCount,
                timedOut: false,
                errors: []
            )
        } catch {
            let attempt = generationAttempt(from: error)
            logDiagnostic(
                "generate_base_error timedOut=\(isTimeout(error)) error=\(error.localizedDescription)",
                aiManager: aiManager
            )
            if !isTimeout(error) {
                try? await recoverModel(aiManager, restoreImprint: false)
            }
            return GeneratedAnswer(
                answer: "",
                toolCalls: [],
                toolTrace: [],
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: attempt?.firstChunkMs,
                ttftMs: attempt?.metrics?.ttftMs,
                generatedTokens: attempt?.metrics?.generationTokenCount,
                timedOut: isTimeout(error),
                errors: [error.localizedDescription]
            )
        }
    }

    private static func generateImprintProfileAnswer(
        prompt: String,
        aiManager: AIManager,
        session: ChatSessionController
    ) async -> GeneratedAnswer {
        let startedAt = Date()
        do {
            try await ensureModelLoaded(aiManager)
            let plain = try await generatePlain(
                prompt: prompt,
                aiManager: aiManager,
                session: session,
                mode: .isolated("smoke_imprint"),
                maxTokens: 96
            )
            return GeneratedAnswer(
                answer: plain.answer,
                toolCalls: toolCallNames(in: plain.answer),
                toolTrace: [],
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: plain.firstChunkMs,
                ttftMs: plain.metrics?.ttftMs,
                generatedTokens: plain.metrics?.generationTokenCount,
                timedOut: false,
                errors: []
            )
        } catch {
            let attempt = generationAttempt(from: error)
            return GeneratedAnswer(
                answer: "",
                toolCalls: [],
                toolTrace: [],
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: attempt?.firstChunkMs,
                ttftMs: attempt?.metrics?.ttftMs,
                generatedTokens: attempt?.metrics?.generationTokenCount,
                timedOut: isTimeout(error),
                errors: [error.localizedDescription]
            )
        }
    }

    private static func generateImprintFactAnswer(
        prompt: String,
        aiManager: AIManager,
        session: ChatSessionController
    ) async -> GeneratedAnswer {
        let startedAt = Date()
        var toolCalls: [String] = []
        var toolTrace: [DomainABToolTrace] = []
        var pendingToolArguments: [String: [String]] = [:]
        var firstChunkMs: Int?
        var metrics: InferenceMetrics?
        do {
            try await ensureModelLoaded(aiManager)
            let toolNames = ScaffoldSampleDomainRegistry.selectedToolNames()
            let toolSpecs = try ToolRegistry.shared.toolSpecs(forNames: toolNames)
            var params = AIManager.defaultParameters(enableThinking: false)
            applySmokeGenerationPolicy(&params, maxTokens: 80)
            let answer = try await ToolChatLoop.run(
                session: session,
                request: ToolChatLoop.Request(
                    messages: [.system(ScaffoldConfig.defaultSystemPrompt), .user(prompt)],
                    mode: .isolated("smoke_imprint"),
                    tools: toolSpecs,
                    allowedToolNames: toolNames,
                    maxRounds: 3,
                    parameters: params,
                    timeoutSeconds: nil,
                    watchdogConfiguration: generationWatchdog,
                    emptyFinalText: ""
                ),
                hooks: ToolChatLoop.Hooks(
                    executePlannedTool: { plan in
                        try await ToolRegistry.shared.execute(plan)
                    },
                    executeModelTool: { toolCall in
                        try await ToolRegistry.shared.execute(toolCall)
                    },
                    summarizeToolResults: { _ in "" },
                    streamSummary: { _, _ in },
                    onModelToolCall: { toolCall in
                        let name = toolCall.function.name
                        toolCalls.append(name)
                        pendingToolArguments[name, default: []].append(
                            argumentsText(toolCall.function.arguments)
                        )
                    },
                    onToolResult: { result in
                        let arguments: String
                        if var queued = pendingToolArguments[result.name], !queued.isEmpty {
                            arguments = queued.removeFirst()
                            pendingToolArguments[result.name] = queued
                        } else {
                            arguments = ""
                        }
                        toolTrace.append(DomainABToolTrace(
                            name: result.name,
                            source: result.source,
                            argumentsPrefix: String(arguments.prefix(300)),
                            matchedCount: toolResultInt(result.result, keys: ["matched_count", "matchedCount"]),
                            totalClassified: toolResultInt(result.result, keys: ["total_classified", "totalClassified"]),
                            totalAmount: toolResultDouble(result.result, keys: ["total_amount", "totalAmount"]),
                            totalDurationMinutes: toolResultDouble(result.result, keys: ["total_duration_minutes", "totalDurationMinutes"]),
                            resultPrefix: String(result.result.prefix(300))
                        ))
                    }
                )
            ) { chunk in
                if firstChunkMs == nil, !chunk.isEmpty {
                    firstChunkMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                }
            }
            metrics = session.lastMetrics
            return GeneratedAnswer(
                answer: answer,
                toolCalls: toolCalls,
                toolTrace: toolTrace,
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: firstChunkMs,
                ttftMs: metrics?.ttftMs,
                generatedTokens: metrics?.generationTokenCount,
                timedOut: false,
                errors: []
            )
        } catch {
            return GeneratedAnswer(
                answer: "",
                toolCalls: toolCalls,
                toolTrace: toolTrace,
                elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                firstChunkMs: firstChunkMs,
                ttftMs: metrics?.ttftMs,
                generatedTokens: metrics?.generationTokenCount,
                timedOut: isTimeout(error),
                errors: [error.localizedDescription]
            )
        }
    }

    private static func generatePlain(
        prompt: String,
        aiManager: AIManager,
        session: ChatSessionController,
        mode: ChatSessionController.Mode,
        maxTokens: Int = 32,
        watchdogConfiguration: EdgeGenerationWatchdog.Configuration = generationWatchdog
    ) async throws -> PlainGeneration {
        let startedAt = Date()
        var firstChunkMs: Int?
        var params = AIManager.defaultParameters(enableThinking: false)
        applySmokeGenerationPolicy(&params, maxTokens: maxTokens)
        do {
            let answer = try await session.runTurn(
                userText: prompt,
                systemPrompt: ScaffoldConfig.defaultSystemPrompt,
                mode: mode,
                parameters: params,
                timeoutSeconds: nil,
                watchdogConfiguration: watchdogConfiguration
            ) { chunk in
                if firstChunkMs == nil, !chunk.isEmpty {
                    firstChunkMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                }
            }
            return PlainGeneration(
                answer: answer,
                firstChunkMs: firstChunkMs,
                metrics: session.lastMetrics
            )
        } catch {
            throw GenerationAttemptError(
                underlying: error,
                firstChunkMs: firstChunkMs,
                metrics: session.lastMetrics
            )
        }
    }

    private static func applySmokeGenerationPolicy(
        _ params: inout EdgeGenerateParameters,
        maxTokens: Int
    ) {
        params.maxTokens = min(params.maxTokens, maxTokens)
        params.minimumGeneratedTokens = 0
        params.eosPenaltyUntilToken = 0
    }

    private static func resetSmokeSession(
        _ session: ChatSessionController,
        aiManager: AIManager,
        reason: String
    ) async {
        session.reset(reason: reason)
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private static func recoverModel(
        _ aiManager: AIManager,
        restoreImprint: Bool
    ) async throws {
        logDiagnostic(
            "recover_begin restoreImprint=\(restoreImprint)",
            aiManager: aiManager
        )
        aiManager.resetChatRuntime(reason: "domain_ab_smoke_recover")
        if aiManager.llmEngine?.state == .ready {
            if restoreImprint {
                _ = await aiManager.restoreNeuralImprintCacheIfAvailable()
            } else {
                deactivateNeuralImprint(aiManager)
            }
            logDiagnostic("recover_reused_ready_runtime", aiManager: aiManager)
            return
        }
        aiManager.unloadModel()
        logDiagnostic("recover_unloaded_not_ready_runtime", aiManager: aiManager)
        try await ensureModelLoaded(aiManager)
        if restoreImprint {
            _ = await aiManager.restoreNeuralImprintCacheIfAvailable()
        } else {
            deactivateNeuralImprint(aiManager)
        }
        logDiagnostic("recover_reload_done", aiManager: aiManager)
    }

    private static func deactivateNeuralImprint(_ aiManager: AIManager) {
        aiManager.llmEngine?.unloadNeuralImprintCache()
        aiManager.neuralImprintCacheStatus = nil
        aiManager.neuralImprintCacheError = nil
        aiManager.resetChatRuntime(reason: "domain_ab_smoke_base")
    }

    private static func logDiagnostic(
        _ label: String,
        domain: ScaffoldSampleDomainDescriptor? = nil,
        aiManager: AIManager
    ) {
        let memory = DeviceProfile.captureMemorySnapshot()
        let domainID = domain?.id.rawValue ?? "none"
        let llmState = String(describing: aiManager.llmEngine?.state)
        let vlmState = String(describing: aiManager.vlmEngine?.state)
        let prefixTokens = aiManager.neuralImprintCacheStatus?.prefixTokenCount ?? 0
        NSLog(
            "[ScaffoldDomainABSmokeRunner] diag label=%@ domain=%@ modelLoaded=%@ llmState=%@ vlmState=%@ restoreEnabled=%@ hasImprint=%@ prefixTokens=%d footprintMB=%d availableMB=%d jetsamLimitMB=%d totalMB=%d",
            label,
            domainID,
            String(aiManager.isModelLoaded),
            llmState,
            vlmState,
            String(aiManager.isNeuralImprintRestoreEnabled),
            String(aiManager.hasNeuralImprintCache),
            prefixTokens,
            memory.footprintMB,
            memory.availableMB,
            memory.jetsamLimitMB,
            memory.totalPhysicalMB
        )
    }

    private static func toolCallNames(in answer: String) -> [String] {
        ToolCallTextParser.toolCalls(in: answer).map(\.function.name)
    }

    private static func answer(_ answer: String, containsAny needles: [String]) -> Bool {
        let normalized = answer.lowercased()
        return needles.contains { normalized.contains($0.lowercased()) }
    }

    private static func toolTraceHasNonEmptyResult(_ trace: [DomainABToolTrace]) -> Bool {
        trace.contains { item in
            if let matchedCount = item.matchedCount {
                return matchedCount > 0
            }
            if let totalAmount = item.totalAmount, totalAmount != 0 {
                return true
            }
            if let totalDurationMinutes = item.totalDurationMinutes, totalDurationMinutes > 0 {
                return true
            }
            return false
        }
    }

    private static func argumentsText(_ arguments: [String: any Sendable]) -> String {
        let parts = arguments.keys.sorted().map { key in
            "\(key)=\(String(describing: arguments[key] ?? ""))"
        }
        return parts.joined(separator: ", ")
    }

    private static func toolResultInt(_ json: String, keys: [String]) -> Int? {
        guard let dict = toolResultDict(json) else { return nil }
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? String, let intValue = Int(value) { return intValue }
        }
        return nil
    }

    private static func toolResultDouble(_ json: String, keys: [String]) -> Double? {
        guard let dict = toolResultDict(json) else { return nil }
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? String, let doubleValue = Double(value) { return doubleValue }
        }
        return nil
    }

    private static func toolResultDict(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func lastRunJSON() -> [String: Any] {
        let url = documentsURL().appendingPathComponent("rpp_last_run.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func lastRunString(_ key: String) -> String? {
        lastRunJSON()[key] as? String
    }

    private static func lastRunBool(_ key: String) -> Bool? {
        lastRunJSON()[key] as? Bool
    }

    private static func generationAttempt(from error: Error) -> GenerationAttemptError? {
        error as? GenerationAttemptError
    }

    private static func isTimeout(_ error: Error) -> Bool {
        let underlying = generationAttempt(from: error)?.underlying ?? error
        if case EdgeChatSessionError.timeout = underlying {
            return true
        }
        return underlying.localizedDescription.lowercased().contains("timed out")
    }

    private static func promptPair(for domain: ScaffoldSampleDomainDescriptor) -> [DomainABPrompt] {
        let general = DomainABPrompt(
            kind: "general",
            text: "中国的首都是哪里？",
            expectedAnswerContainsAny: ["北京", "Beijing"]
        )
        switch domain.id {
        case .finance:
            return [
                .init(kind: "profile", text: "我的消费习惯是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一条餐饮消费记录是哪天、在哪里、多少钱？",
                    expectedToolName: ScaffoldTooling.expenseSearchToolName,
                    acceptedToolNames: [
                        ScaffoldTooling.expenseSearchToolName,
                        ScaffoldTooling.expenseSummaryToolName,
                    ]
                ),
                general,
            ]
        case .health:
            return [
                .init(kind: "profile", text: "我的运动习惯是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一次跑步记录是哪天，距离和配速是多少？",
                    expectedToolName: ScaffoldHealthTooling.workoutToolName,
                    acceptedToolNames: [ScaffoldHealthTooling.workoutToolName]
                ),
                general,
            ]
        case .reading:
            return [
                .init(kind: "profile", text: "我的阅读偏好是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一条技术书阅读记录是哪本书、读到哪里？",
                    expectedToolName: ScaffoldReadingTooling.readingHistoryToolName,
                    acceptedToolNames: [
                        ScaffoldReadingTooling.readingHistoryToolName,
                        ScaffoldReadingTooling.notesToolName,
                    ]
                ),
                general,
            ]
        case .journal:
            return [
                .init(kind: "profile", text: "我最近的状态怎么样？"),
                .init(
                    kind: "fact",
                    text: "最近一条高优先级任务的标题和截止日期是什么？",
                    expectedToolName: ScaffoldJournalTooling.tasksToolName,
                    acceptedToolNames: [ScaffoldJournalTooling.tasksToolName]
                ),
                general,
            ]
        case .travel:
            return [
                .init(kind: "profile", text: "我的旅行偏好是什么？"),
                .init(
                    kind: "fact",
                    text: "帮我查一下本机旅行记录中最新一条的日期、目的地和记录类型。",
                    expectedToolName: ScaffoldTravelTooling.recordsToolName,
                    acceptedToolNames: [ScaffoldTravelTooling.recordsToolName]
                ),
                general,
            ]
        case .cooking:
            return [
                .init(kind: "profile", text: "我的饮食偏好是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一条买菜采购记录是哪天，买了哪些食材？",
                    expectedToolName: ScaffoldCookingTooling.recordsToolName,
                    acceptedToolNames: [ScaffoldCookingTooling.recordsToolName]
                ),
                general,
            ]
        case .music:
            return [
                .init(kind: "profile", text: "我的音乐品味是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一条音乐收听记录是什么内容？",
                    expectedToolName: ScaffoldMusicTooling.recordsToolName,
                    acceptedToolNames: [ScaffoldMusicTooling.recordsToolName]
                ),
                general,
            ]
        case .work:
            return [
                .init(kind: "profile", text: "我的工作模式是什么？"),
                .init(
                    kind: "fact",
                    text: "最近一条工作记录属于哪个项目，内容是什么？",
                    expectedToolName: ScaffoldWorkTooling.recordsToolName,
                    acceptedToolNames: [ScaffoldWorkTooling.recordsToolName]
                ),
                general,
            ]
        }
    }

    private static func acceptedToolNames(
        for prompt: DomainABPrompt,
        domain: ScaffoldSampleDomainDescriptor
    ) -> [String] {
        if !prompt.acceptedToolNames.isEmpty {
            return prompt.acceptedToolNames
        }
        if let expectedToolName = prompt.expectedToolName {
            return [expectedToolName]
        }
        return []
    }

    private static func isTransientDatabaseLock(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("database is locked") || text.contains("sqlite error 5")
    }

    private static func selectedDomains() -> [ScaffoldSampleDomainDescriptor] {
        let args = ProcessInfo.processInfo.arguments
        guard let rawValue = args.compactMap({ arg -> String? in
            guard arg.hasPrefix(domainArgumentPrefix) else { return nil }
            return String(arg.dropFirst(domainArgumentPrefix.count))
        }).last, !rawValue.isEmpty else {
            return ScaffoldSampleDomainRegistry.all
        }
        let requested = Set(
            rawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !requested.isEmpty else {
            return ScaffoldSampleDomainRegistry.all
        }
        return ScaffoldSampleDomainRegistry.all.filter { requested.contains($0.id.rawValue) }
    }

    private static func writeCheckpoint(
        startedAt: Date,
        topLevelErrors: [String],
        results: [DomainABResult]
    ) {
        let now = Date()
        let report = DomainABSmokeReport(
            schemaVersion: reportSchemaVersion,
            startedAt: isoString(from: startedAt),
            finishedAt: isoString(from: now),
            durationMs: Int(now.timeIntervalSince(startedAt) * 1_000),
            passed: false,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            runtimeMetadata: runtimeMetadata(),
            modelID: ScaffoldConfig.modelID,
            topLevelErrors: topLevelErrors,
            results: results
        )
        do {
            try write(report)
        } catch {
            NSLog("[ScaffoldDomainABSmokeRunner] checkpoint write failed: \(error.localizedDescription)")
        }
    }

    private static func write(_ report: DomainABSmokeReport) throws {
        let url = documentsURL().appendingPathComponent(resultFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func runtimeMetadata() -> DomainABSmokeRuntimeMetadata {
        let hostMetadata = hostBuildMetadata()
        return DomainABSmokeRuntimeMetadata(
            edgeKitVersion: EdgeKitRuntime.version,
            edgeEngineVersion: EdgeKitRuntime.nativeRuntimeVersion,
            appBuild: DomainABSmokeAppBuildMetadata(
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

    private static func hostBuildMetadata() -> DomainABSmokeBuildMetadata? {
        let url = documentsURL().appendingPathComponent("device_test_build_metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DomainABSmokeBuildMetadata.self, from: data)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct DomainABSmokeReport: Encodable {
    let schemaVersion: String
    let startedAt: String
    let finishedAt: String
    let durationMs: Int
    let passed: Bool
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let runtimeMetadata: DomainABSmokeRuntimeMetadata
    let modelID: String
    let topLevelErrors: [String]
    let results: [DomainABResult]
}

private struct DomainABSmokeBuildMetadata: Decodable {
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}

private struct DomainABSmokeRuntimeMetadata: Encodable {
    let edgeKitVersion: String
    let edgeEngineVersion: String
    let appBuild: DomainABSmokeAppBuildMetadata
}

private struct DomainABSmokeAppBuildMetadata: Encodable {
    let bundleIdentifier: String
    let appVersion: String
    let buildNumber: String
    let gitSHAs: [String: String]
    let dependencyVersions: [String: String]
    let demoReadyTag: String?
    let demoReadyTagExact: Bool
}

private struct DomainABResult: Encodable {
    let domain: String
    let displayName: String
    let namespace: String
    let expectedRecords: Int
    let seedStats: DomainABSeedStats?
    let rpp: DomainABRPPResult?
    let prompts: [DomainABPromptResult]
    let durationMs: Int
    let passed: Bool
    let errors: [String]
}

private struct DomainABSeedStats: Encodable {
    let sampleRecords: Int
    let writtenThisRun: Int
    let rawUnclassified: Int
    let classified: Int
    let total: Int

    init(_ result: ScaffoldSampleDomainSeedResult) {
        sampleRecords = result.sampleRecords
        writtenThisRun = result.writtenThisRun
        rawUnclassified = result.rawUnclassified
        classified = result.classified
        total = result.total
    }
}

private struct DomainABRPPResult: Encodable {
    let datasetSize: Int
    let directionsCount: Int
    let targetLayer: Int
    let totalElapsedSeconds: Double
    let imprintActive: Bool
    let prefixTokens: Int
    let aLibraryID: String?
    let directionSetID: String?
    let aHealthVerdict: String?
    let aHealthReport: String?
    let aYAMLSHA256: String?
    let aSourceType: String?
    let aSourceSchemaVersion: String?
    let usedFallback: Bool?
}

private struct DomainABPrompt: Encodable {
    let kind: String
    let text: String
    var expectedToolName: String? = nil
    var acceptedToolNames: [String] = []
    var expectedAnswerContainsAny: [String] = []
}

private enum ControlledArm: String, CaseIterable {
    case basePlain = "base_plain"
    case visibleProfilePlain = "visible_profile_plain"
    case toolsNoImprint = "tools_no_imprint"
    case visibleProfileToolsLive = "visible_profile_tools_live"
    case imprint

    var profileInContext: Bool {
        switch self {
        case .basePlain, .toolsNoImprint:
            return false
        case .visibleProfilePlain, .visibleProfileToolsLive, .imprint:
            return true
        }
    }

    var toolsInContext: Bool {
        switch self {
        case .basePlain, .visibleProfilePlain:
            return false
        case .toolsNoImprint, .visibleProfileToolsLive, .imprint:
            return true
        }
    }

    var prefixDelivery: String {
        self == .imprint ? "restored_kv" : "live_prefill"
    }
}

private struct ControlledRunResult {
    let prompts: [DomainABPromptResult]
    let errors: [String]
}

private struct ControlledGeneration {
    let answer: String
    let toolCalls: [String]
    let toolTrace: [DomainABToolTrace]
    let elapsedMs: Int
    let firstChunkMs: Int?
    let metrics: InferenceMetrics?
    let timedOut: Bool
    let errors: [String]
}

private struct DomainABPromptResult: Encodable {
    let kind: String
    let prompt: String
    let expectedToolName: String?
    let acceptedToolNames: [String]
    let expectedAnswerContainsAny: [String]
    var baseAnswer: String
    var imprintAnswer: String
    var imprintActive: Bool
    var prefixTokens: Int
    var toolCallsBase: [String]
    var toolCallsImprint: [String]
    var toolTrace: [DomainABToolTrace]
    var controlledArms: [DomainABControlledArmResult]
    var deltaSummary: String
    var elapsedBaseMs: Int
    var elapsedImprintMs: Int
    var baseFirstChunkMs: Int?
    var imprintFirstChunkMs: Int?
    var baseTTFTMs: Double?
    var imprintTTFTMs: Double?
    var baseGeneratedTokens: Int?
    var imprintGeneratedTokens: Int?
    var baseTimedOut: Bool
    var imprintTimedOut: Bool
    var errors: [String]
}

private struct DomainABControlledArmResult: Encodable {
    let arm: String
    let repeatIndex: Int
    let executionSequence: Int
    let profileInContext: Bool
    let prefixDelivery: String
    let toolsInContext: Bool
    let answer: String
    let neuralImprintActive: Bool
    let prefixTokens: Int
    let profileBodySHA256: String?
    let prefixTokenIDsSHA256: String?
    let artifactPrefixTokenIDsSHA256: String?
    let prefixTokenHashMatched: Bool?
    let systemPromptSHA256: String?
    let toolSchemaSHA256: String?
    let toolCalls: [String]
    let toolTrace: [DomainABToolTrace]
    let elapsedMs: Int
    let firstChunkMs: Int?
    let ttftMs: Double?
    let decodeTPS: Double?
    let promptTokenCount: Int?
    let prefillTokenCount: Int?
    let prefillMs: Double?
    let prefillMode: String?
    let generatedTokens: Int?
    let promptCacheHit: Bool?
    let cachedTokensReused: Int?
    let thermalState: String?
    let memoryBeforeMB: Int?
    let memoryAfterMB: Int?
    let policyReasoning: String?
    let maxTokens: Int
    let maxRounds: Int
    let turnTimeoutSeconds: Double
    let livenessTimeoutSeconds: Double
    let enableThinking: Bool
    let preserveThinking: Bool
    let useDSR: Bool
    let kvBits: Int?
    let maxKVSize: Int?
    let prefillStepSize: Int
    let frogJumpEnabled: Bool
    let timedOut: Bool
    let errors: [String]
}

private struct DomainABToolTrace: Encodable {
    let name: String
    let source: String
    let argumentsPrefix: String
    let matchedCount: Int?
    let totalClassified: Int?
    let totalAmount: Double?
    let totalDurationMinutes: Double?
    let resultPrefix: String
}

private struct GeneratedAnswer {
    let answer: String
    let toolCalls: [String]
    let toolTrace: [DomainABToolTrace]
    let elapsedMs: Int
    let firstChunkMs: Int?
    let ttftMs: Double?
    let generatedTokens: Int?
    let timedOut: Bool
    let errors: [String]
}

private struct PlainGeneration {
    let answer: String
    let firstChunkMs: Int?
    let metrics: InferenceMetrics?
}

private struct GenerationAttemptError: LocalizedError {
    let underlying: Error
    let firstChunkMs: Int?
    let metrics: InferenceMetrics?

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private enum ABRunnerError: LocalizedError {
    case unsupportedRuntime(String)
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case seedStatsUnavailable
    case rppDidNotStart
    case rppFailed(String)
    case rppMissingOutput
    case imprintInactiveAfterRPP

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime(let runtime):
            return "Domain A/B smoke requires LLM runtime, got \(runtime)"
        case .modelUnavailable(let message):
            return message
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .seedStatsUnavailable:
            return "Seed stats unavailable"
        case .rppDidNotStart:
            return "RPP did not start"
        case .rppFailed(let reason):
            return reason
        case .rppMissingOutput:
            return "RPP finished without output"
        case .imprintInactiveAfterRPP:
            return "Neural Imprint inactive after RPP"
        }
    }
}
