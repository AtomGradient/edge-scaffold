// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeVoice

extension DemoChatView {


    func startTTSGeneration(text: String) {
        messages.append(DisplayMessage(role: .user, content: text))
        let generationID = beginGeneration(status: .scaffoldSpeaking)
        currentResponse = "Generating..."

        generationTask = Task(priority: .userInitiated) { @MainActor in
            await Task.yield()
            do {
                try Task.checkCancellation()
                let sampleRate = aiManager.ttsEngine?.sampleRate ?? 24000

                let streamPlayer = StreamingAudioPlayer()
                try streamPlayer.start(sampleRate: sampleRate)
                defer { streamPlayer.stop() }

                var allSamples: [Float] = []
                var didUpdateToPlaying = false

                let instruct: String? = aiManager.ttsModelType == "voice_design" ? instructText : nil
                for try await event in aiManager.speakStream(text, voice: selectedVoice, instruct: instruct) {
                    try Task.checkCancellation()
                    guard isActiveGeneration(generationID) else { throw CancellationError() }
                    switch event {
                    case .progress:
                        break

                    case .audioChunk(let chunk):
                        allSamples.append(contentsOf: chunk.samples)
                        try streamPlayer.scheduleChunk(StreamingAudioChunk(
                            samples: chunk.samples,
                            sampleRate: chunk.sampleRate,
                            chunkIndex: chunk.chunkIndex,
                            generationTimeMs: chunk.generationTimeMs
                        ))

                        if !didUpdateToPlaying && streamPlayer.isPlaying {
                            currentResponse = "Playing..."
                            didUpdateToPlaying = true
                        }

                    case .audio(let result):
                        if allSamples.isEmpty {
                            allSamples.append(contentsOf: result.samples)
                            try streamPlayer.scheduleChunk(
                                samples: result.samples,
                                sampleRate: result.sampleRate
                            )
                        }
                    }
                }

                try streamPlayer.markComplete()
                if !didUpdateToPlaying {
                    currentResponse = "Playing..."
                }

                await streamPlayer.waitForPlaybackEnd()
                try Task.checkCancellation()

                if !allSamples.isEmpty {
                    if isActiveGeneration(generationID) {
                        messages.append(DisplayMessage(
                            role: .assistant,
                            content: String(format: "Audio: %.1fs", Double(allSamples.count) / Double(sampleRate)),
                            audioSamples: allSamples,
                            sampleRate: sampleRate
                        ))
                    }
                }
            } catch is CancellationError {
            } catch {
                if isActiveGeneration(generationID) {
                    messages.append(DisplayMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                }
            }
            await finishGeneration(generationID)
        }
    }
}
