// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import Foundation
import EdgeInference
import EdgeSession

private final class JointInferenceChunkAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let current = text
        lock.unlock()
        return current
    }
}

private final class JointInferenceUIThrottle: @unchecked Sendable {
    struct Batch {
        let text: String
        let tokenCount: Int
    }

    let flushDelayNanoseconds: UInt64

    private let lock = NSLock()
    private var pendingText = ""
    private var pendingTokenCount = 0
    private var isFlushScheduled = false

    init(interval: TimeInterval = 0.05) {
        self.flushDelayNanoseconds = UInt64(max(interval, 0) * 1_000_000_000)
    }

    func append(_ token: String) -> Bool {
        lock.lock()
        pendingText += token
        pendingTokenCount += 1
        if isFlushScheduled {
            lock.unlock()
            return false
        }
        isFlushScheduled = true
        lock.unlock()
        return true
    }

    func drain() -> Batch {
        lock.lock()
        let batch = Batch(text: pendingText, tokenCount: pendingTokenCount)
        pendingText = ""
        pendingTokenCount = 0
        isFlushScheduled = false
        lock.unlock()
        return batch
    }
}

private final class JointInferenceToolCallStreamGate: @unchecked Sendable {
    private enum Mode {
        case undecided
        case passThrough
        case suppressToolCall
    }

    private let lock = NSLock()
    private var mode: Mode = .undecided
    private var bufferedText = ""
    private let detectionWindow = 96

    func append(_ token: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        switch mode {
        case .passThrough:
            return token
        case .suppressToolCall:
            return ""
        case .undecided:
            bufferedText += token
            if Self.containsToolCallStart(bufferedText) {
                bufferedText = ""
                mode = .suppressToolCall
                return ""
            }
            if bufferedText.count >= detectionWindow {
                let text = bufferedText
                bufferedText = ""
                mode = .passThrough
                return text
            }
            return ""
        }
    }

    func flushDisplayText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .undecided else { return "" }
        let text = bufferedText
        bufferedText = ""
        mode = .passThrough
        return text
    }

    private static func containsToolCallStart(_ text: String) -> Bool {
        text.contains("<tool_call") || text.contains("<function=")
    }
}

extension DemoChatView {

    func startLLMGeneration(text: String) {
        guard !isGenerating else { return }
        messages.append(DisplayMessage(role: .user, content: text))
        let generationID = beginGeneration(
            status: meshManager.canUseJointInference ? .scaffoldJointInference : .scaffoldThinking
        )

        let startTime = Date()
        let params = AIManager.defaultParameters(enableThinking: enableThinking)

        generationTask = Task(priority: .userInitiated) { @MainActor in
            await Task.yield()
            await runLLMGenerationTask(
                text: text,
                params: params,
                startTime: startTime,
                generationID: generationID
            )
        }
    }

    private func runLLMGenerationTask(
        text: String,
        params: EdgeGenerateParameters,
        startTime: Date,
        generationID: UUID
    ) async {
        AIManager.shared.generationTokenCountObserver = { generatedTokenCount in
            guard isActiveGeneration(generationID) else { return }
            updateActivityOutputTokens(generatedTokenCount)
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
                tokensPerSecond = Double(generatedTokenCount) / elapsed
            }
        }
        defer {
            AIManager.shared.generationTokenCountObserver = nil
        }

        do {
            try Task.checkCancellation()
            if meshManager.canUseJointInference {
                try await runJointInferenceTurn(
                    text: text,
                    params: params,
                    startTime: startTime,
                    generationID: generationID
                )
                await finishGeneration(generationID)
                return
            }

            try await runLocalToolAwareTurn(
                text: text,
                params: params,
                startTime: startTime,
                generationID: generationID
            )
        } catch is CancellationError {
            chatHistory = chatSession.history
        } catch {
            chatHistory = chatSession.history
            if isActiveGeneration(generationID) {
                messages.append(DisplayMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
            }
        }
        await finishGeneration(generationID)
    }

    private func runJointInferenceTurn(
        text: String,
        params: EdgeGenerateParameters,
        startTime: Date,
        generationID: UUID
    ) async throws {
        let conversationID = await ensureCurrentConversationIDForJointInference()?.uuidString
        let preparedMessages = preparedJointInferenceHistory(appending: text)
        let rawReply = try await runJointInferenceRequest(
            messages: preparedMessages,
            conversationID: conversationID,
            params: params,
            startTime: startTime,
            generationID: generationID,
            suppressToolCallDisplay: true
        )
        try Task.checkCancellation()

        let finalReply: String
        let finalHistory: [ChatMessage]
        if let toolMessages = try await jointInferenceToolMessages(from: rawReply) {
            guard isActiveGeneration(generationID) else { throw CancellationError() }
            currentResponse = ""
            updateActivityOutputTokens(0)
            let continuationMessages = Self.compactJointInferenceHistory(
                preparedMessages
                + toolMessages
            )
            finalReply = try await runJointInferenceRequest(
                messages: continuationMessages,
                conversationID: conversationID,
                params: params,
                startTime: startTime,
                generationID: generationID,
                suppressToolCallDisplay: true
            )
            finalHistory = continuationMessages + [.assistant(finalReply)]
        } else {
            finalReply = rawReply
            finalHistory = preparedMessages + [.assistant(finalReply)]
        }
        chatHistory = Self.compactJointInferenceHistory(
            finalHistory
        )
        if isActiveGeneration(generationID) {
            messages.append(DisplayMessage(role: .assistant, content: finalReply))
        }
    }

    private func runJointInferenceRequest(
        messages: [ChatMessage],
        conversationID: String?,
        params: EdgeGenerateParameters,
        startTime: Date,
        generationID: UUID,
        suppressToolCallDisplay: Bool
    ) async throws -> String {
        var tokenCount = 0
        setActivityStatus(.scaffoldJointInference)
        let streamAccumulator = JointInferenceChunkAccumulator()
        let uiThrottle = JointInferenceUIThrottle()
        let toolCallGate = suppressToolCallDisplay ? JointInferenceToolCallStreamGate() : nil
        let reply = try await meshManager.meshJointInferenceGenerate(
            messages: Self.jointInferenceMessages(from: messages),
            conversationID: conversationID,
            maxTokens: params.maxTokens,
            temperature: Double(params.temperature),
            enableThinking: enableThinking,
            useNeuralImprint: aiManager.hasNeuralImprintCache,
            onEvent: { event in
                guard event.type == .token,
                      let token = event.token,
                      !token.isEmpty
                else { return }
                streamAccumulator.append(token)
                let displayText = toolCallGate?.append(token) ?? token
                guard !displayText.isEmpty, uiThrottle.append(displayText) else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: uiThrottle.flushDelayNanoseconds)
                    guard isActiveGeneration(generationID) else { return }
                    let batch = uiThrottle.drain()
                    guard !batch.text.isEmpty else { return }
                    if currentResponse.isEmpty {
                        setActivityStatus(.scaffoldAnswering)
                    }
                    currentResponse += batch.text
                    tokenCount += batch.tokenCount
                    updateActivityOutputTokens(tokenCount)
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 { tokensPerSecond = Double(tokenCount) / elapsed }
                }
            }
        )
        try Task.checkCancellation()

        if let gatedTail = toolCallGate?.flushDisplayText(), !gatedTail.isEmpty {
            _ = uiThrottle.append(gatedTail)
        }
        let remaining = uiThrottle.drain()
        if !remaining.text.isEmpty {
            guard isActiveGeneration(generationID) else { throw CancellationError() }
            if currentResponse.isEmpty {
                setActivityStatus(.scaffoldAnswering)
            }
            currentResponse += remaining.text
            tokenCount += remaining.tokenCount
            updateActivityOutputTokens(tokenCount)
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 { tokensPerSecond = Double(tokenCount) / elapsed }
        }

        let streamedReply = streamAccumulator.snapshot()
        let finalReply = reply.isEmpty ? streamedReply : reply
        if streamedReply.isEmpty,
           !reply.isEmpty,
           !(suppressToolCallDisplay && ToolCallTextParser.containsToolCall(reply)) {
            currentResponse = reply
        }
        return finalReply
    }

    private func jointInferenceToolMessages(
        from rawReply: String
    ) async throws -> [ChatMessage]? {
        let toolCalls = ToolCallTextParser.toolCalls(in: rawReply)
        guard !toolCalls.isEmpty else { return nil }

        let selectedToolNames = ScaffoldSampleDomainRegistry.selectedToolNames()
        let allowedToolNames = Set(selectedToolNames)
        var toolMessages: [ChatMessage] = [.assistant(rawReply)]
        for toolCall in toolCalls {
            let name = toolCall.function.name
            let output: String
            if allowedToolNames.contains(name) {
                do {
                    output = try await ToolRegistry.shared.execute(toolCall)
                } catch {
                    output = "{\"error\":\"\(Self.escapeJSONString(error.localizedDescription))\"}"
                }
            } else {
                output = "{\"error\":\"tool '\\(Self.escapeJSONString(name))' is not registered in EdgeScaffold\"}"
            }
            toolMessages.append(.tool("[\(name)] \(output)"))
            NSLog("[ScaffoldJointInference] tool_call name=%@ result_chars=%d", name, output.count)
        }
        return toolMessages
    }

    private func runLocalToolAwareTurn(
        text: String,
        params: EdgeGenerateParameters,
        startTime: Date,
        generationID: UUID
    ) async throws {
        var tokenCount = 0
        setActivityStatus(.scaffoldThinking)
        guard aiManager.hasNeuralImprintCache else {
            NSLog("[ScaffoldToolLoop] autonomous_tool_call disabled reason=neural_imprint_required")
            try await runPlainLocalTurn(
                text: text,
                params: params,
                startTime: startTime,
                generationID: generationID
            )
            return
        }

        let toolSpecs = try ToolRegistry.shared.toolSpecs(
            forNames: ScaffoldSampleDomainRegistry.selectedToolNames()
        )
        guard !toolSpecs.isEmpty else {
            try await runPlainLocalTurn(
                text: text,
                params: params,
                startTime: startTime,
                generationID: generationID
            )
            return
        }

        let preparedMessages = preparedLocalHistory(appending: text)
        let reply = try await ToolChatLoop.run(
            session: chatSession,
            request: ToolChatLoop.Request(
                messages: preparedMessages,
                mode: .tool,
                tools: toolSpecs,
                allowedToolNames: ScaffoldSampleDomainRegistry.selectedToolNames(),
                maxRounds: 3,
                parameters: params,
                timeoutSeconds: 120,
                emptyFinalText: "Neural Imprint is active, but the model did not form a reliable tool answer."
            ),
            hooks: ToolChatLoop.Hooks(
                executePlannedTool: { plan in
                    try await ToolRegistry.shared.execute(plan)
                },
                executeModelTool: { toolCall in
                    try await ToolRegistry.shared.execute(toolCall)
                },
                summarizeToolResults: { results in
                    ScaffoldTooling.userVisibleSummary(for: results)
                },
                streamSummary: { summary, emitChunk in
                    guard isActiveGeneration(generationID) else { return }
                    currentResponse = ""
                    setActivityStatus(.scaffoldAnswering)
                    await streamScaffoldToolSummary(summary, onChunk: emitChunk)
                },
                onModelToolCall: { toolCall in
                    NSLog("[ScaffoldToolLoop] tool_call name=%@", toolCall.function.name)
                },
                onToolResult: { result in
                    NSLog("[ScaffoldToolLoop] tool_result name=%@ chars=%d", result.name, result.result.count)
                },
                onToolSummary: { summary, results in
                    NSLog("[ScaffoldToolLoop] summary chars=%d tool_results=%d", summary.count, results.count)
                },
                onRoundWillContinue: { _ in
                    guard isActiveGeneration(generationID) else { return }
                    currentResponse = ""
                    tokenCount = 0
                    setActivityStatus(.scaffoldAnswering)
                }
            )
        ) { token in
            guard isActiveGeneration(generationID) else { return }
            if currentResponse.isEmpty {
                setActivityStatus(.scaffoldAnswering)
            }
            currentResponse += token
            if aiManager.currentGenerationTokenCount == nil {
                tokenCount += 1
                updateActivityOutputTokens(tokenCount)
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 { tokensPerSecond = Double(tokenCount) / elapsed }
            }
        }
        try Task.checkCancellation()
        chatHistory = Self.compactJointInferenceHistory(
            preparedMessages + [.assistant(reply)]
        )
        chatSession.replaceHistory(chatHistory, mode: .tool)
        if isActiveGeneration(generationID) {
            messages.append(DisplayMessage(role: .assistant, content: reply))
        }
        if let metrics = chatSession.lastMetrics {
            tokensPerSecond = metrics.decodeTPS
        }
    }

    private func runPlainLocalTurn(
        text: String,
        params: EdgeGenerateParameters,
        startTime: Date,
        generationID: UUID
    ) async throws {
        var tokenCount = 0
        let reply = try await chatSession.runTurn(
            userText: text,
            systemPrompt: ScaffoldConfig.defaultSystemPrompt,
            mode: .plain,
            parameters: params
        ) { token in
            guard isActiveGeneration(generationID) else { return }
            if currentResponse.isEmpty {
                setActivityStatus(.scaffoldAnswering)
            }
            currentResponse += token
            if aiManager.currentGenerationTokenCount == nil {
                tokenCount += 1
                updateActivityOutputTokens(tokenCount)
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 { tokensPerSecond = Double(tokenCount) / elapsed }
            }
        }
        try Task.checkCancellation()
        chatHistory = chatSession.history
        if isActiveGeneration(generationID) {
            messages.append(DisplayMessage(role: .assistant, content: reply))
        }
        if let metrics = chatSession.lastMetrics {
            tokensPerSecond = metrics.decodeTPS
        }
    }

    private func preparedLocalHistory(appending userText: String) -> [ChatMessage] {
        var prepared = chatHistory
        if prepared.isEmpty {
            prepared.append(.system(ScaffoldConfig.defaultSystemPrompt))
        } else if prepared.first?.role == .system {
            prepared[0] = .system(ScaffoldConfig.defaultSystemPrompt)
        } else {
            prepared.insert(.system(ScaffoldConfig.defaultSystemPrompt), at: 0)
        }
        prepared.append(.user(userText))
        return Self.compactJointInferenceHistory(prepared)
    }

    private func preparedJointInferenceHistory(appending userText: String) -> [ChatMessage] {
        var prepared = chatHistory
        if prepared.isEmpty {
            prepared.append(.system(ScaffoldConfig.defaultSystemPrompt))
        } else if prepared.first?.role == .system {
            prepared[0] = .system(ScaffoldConfig.defaultSystemPrompt)
        } else {
            prepared.insert(.system(ScaffoldConfig.defaultSystemPrompt), at: 0)
        }
        prepared.append(.user(userText))
        return Self.compactJointInferenceHistory(prepared)
    }

    private static func compactJointInferenceHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        HistoryCompactor.compact(
            messages,
            config: .init(
                maxMessages: 12,
                characterBudget: 8_000,
                preserveSystemPrompt: true,
                preserveLastNTurns: 2
            )
        )
    }

    private static func jointInferenceMessages(from messages: [ChatMessage]) -> [[String: String]] {
        messages.map { message in
            [
                "role": message.roleString,
                "content": message.content,
            ]
        }
    }

    @MainActor
    private func streamScaffoldToolSummary(
        _ summary: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async {
        for chunk in Self.displayChunks(summary, targetSize: 18) {
            onChunk(chunk)
            try? await Task.sleep(nanoseconds: 18_000_000)
        }
    }

    private static func displayChunks(_ text: String, targetSize: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var buffer = ""
        for char in text {
            buffer.append(char)
            if buffer.count >= targetSize || char == "\n" || char == "。" || char == "，" {
                chunks.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
    }

    private static func escapeJSONString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
