// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeData
import EdgeInference
import Tokenizers


enum ScaffoldDemoSchema {

    static let namespace = "scaffold"
    static let schemaName = "scaffold.activity"

    static func register() {
        Edge.registerSchema(SchemaDef(
            name: schemaName,
            fields: [
                FieldDef(name: "description", type: .text, required: true),
                FieldDef(name: "category", type: .categorical([
                    "dining", "transport", "shopping", "entertainment",
                    "utilities", "healthcare", "education", "subscription", "other"
                ]), required: true),
                FieldDef(name: "amount", type: .numeric, required: true),
                FieldDef(name: "location", type: .entity, required: false),
            ],
            semanticLabels: SemanticLabels(
                primaryTimestamp: nil,
                primaryValue: "amount",
                primaryEntity: "description"
            )
        ))
    }

    static let sampleRecords: [(description: String, rawPayload: [String: Any])] = [
        ("Coffee at Starbucks, $4.50", [
            "text": "Coffee at Starbucks, $4.50",
            "source": "manual_input"
        ]),
        ("Uber ride to airport, $35.00", [
            "text": "Uber ride to airport, $35.00",
            "source": "manual_input"
        ]),
        ("Netflix monthly subscription, $15.99", [
            "text": "Netflix monthly subscription, $15.99",
            "source": "manual_input"
        ]),
        ("Grocery shopping at Walmart, $87.30", [
            "text": "Grocery shopping at Walmart, $87.30",
            "source": "manual_input"
        ]),
        ("Gym membership renewal, $45.00", [
            "text": "Gym membership renewal, $45.00",
            "source": "manual_input"
        ]),
    ]

    @discardableResult
    static func insertSampleData() -> [String] {
        var ids: [String] = []
        for record in sampleRecords {
            do {
                let factId = try Edge.recordRaw(
                    fact: RawFact(
                        namespace: namespace,
                        rawPayload: record.rawPayload,
                        candidateSchemas: [schemaName],
                        sensitivity: .meshOk
                    )
                )
                ids.append(factId)
            } catch {
                NSLog("[ScaffoldClassification] insertSampleData failed: \(error)")
            }
        }
        NSLog("[ScaffoldClassification] inserted \(ids.count) sample raw facts")
        return ids
    }
}


@MainActor
final class ScaffoldLLMClient: EdgeClassificationLLMClient {

    static let shared = ScaffoldLLMClient()
    private init() {}

    var isBusy: Bool {
        false
    }

    func generate(messages: [[String: String]]) async -> String {
        return await generateImpl(messages: messages)
    }

    func generate(messages: [[String: String]], toolNames: [String]) async -> String {
        return await generateImpl(messages: messages, toolNames: toolNames)
    }

    private func generateImpl(
        messages: [[String: String]],
        toolNames: [String] = []
    ) async -> String {
        let ai = AIManager.shared
        guard ai.isModelLoaded else {
            return "{\"schema\": \"__failed__\", \"confidence\": 0, \"reasoning\": \"model not loaded\"}"
        }

        let chatMessages: [ChatMessage] = messages.compactMap { dict in
            guard let role = dict["role"], let content = dict["content"] else { return nil }
            switch role {
            case "system": return .system(content)
            case "user": return .user(content)
            case "assistant": return .assistant(content)
            default: return .user(content)
            }
        }

        var params = EdgeGenerateParameters.default
        params.maxTokens = 512
        params.enableThinking = false

        let missingToolNames = toolNames.filter { ToolRegistry.shared.tool(named: $0) == nil }
        if !missingToolNames.isEmpty {
            NSLog("[ScaffoldLLMClient] missing tools: \(missingToolNames)")
            return "{\"schema\": \"__failed__\", \"confidence\": 0, \"reasoning\": \"missing tool registration\"}"
        }

        let toolSpecs: [ToolSpec]
        do {
            toolSpecs = try toolNames.isEmpty ? [] : ToolRegistry.shared.toolSpecs(forNames: toolNames)
        } catch {
            NSLog("[ScaffoldLLMClient] tool schema conversion failed: \(error)")
            return "{\"schema\": \"__failed__\", \"confidence\": 0, \"reasoning\": \"tool schema conversion failed\"}"
        }

        var output = ""
        let stream: AsyncThrowingStream<String, Error>
        if toolSpecs.isEmpty {
            stream = ai.generate(messages: chatMessages, parameters: params)
        } else {
            stream = ai.generate(
                messages: chatMessages,
                tools: toolSpecs,
                onToolCall: { (toolCall: ToolCall) async throws -> String in
                    try await ToolRegistry.shared.execute(toolCall)
                },
                parameters: params
            )
        }
        do {
            for try await chunk in stream {
                output += chunk
            }
        } catch {
            NSLog("[ScaffoldLLMClient] generate error: \(error)")
            return "{\"schema\": \"__failed__\", \"confidence\": 0, \"reasoning\": \"\(error.localizedDescription)\"}"
        }
        return output
    }
}
