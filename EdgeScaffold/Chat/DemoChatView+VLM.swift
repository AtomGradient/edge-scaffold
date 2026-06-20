// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import CoreImage
import PhotosUI
import EdgeInference
import EdgeSession

extension DemoChatView {


    func startVLMGeneration(text: String) {
        messages.append(DisplayMessage(role: .user, content: text, imageData: selectedImageData))

        let ciImages: [CIImage] = selectedCIImage.map { [$0] } ?? []
        clearSelectedImage()

        let generationID = beginGeneration(status: .scaffoldThinking)

        let startTime = Date()
        var tokenCount = 0

        let params = AIManager.defaultParameters(enableThinking: enableThinking)

        generationTask = Task(priority: .userInitiated) { @MainActor in
            await Task.yield()
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
                let reply = try await chatSession.runTurn(
                    userText: text,
                    systemPrompt: ScaffoldConfig.defaultSystemPrompt,
                    mode: .plain,
                    images: ciImages,
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
    }


    func loadSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                selectedImageData = data
                if let ciImage = CIImage(data: data) {
                    selectedCIImage = ciImage
                }
            }
        } catch {
            debugPrint("[DemoChatView] Photo load failed: \(error)")
        }
    }

    func clearSelectedImage() {
        selectedPhoto = nil
        selectedImageData = nil
        selectedCIImage = nil
    }
}
