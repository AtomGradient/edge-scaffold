// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import AVFoundation
import EdgeInference

extension DemoChatView {


    func handleImportedAudio(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            startSTTTranscription(audioURL: tempURL, label: url.lastPathComponent)
        } catch {
            debugPrint("[DemoChatView] Audio import failed: \(error)")
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            debugPrint("[DemoChatView] Audio session setup failed: \(error)")
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stt_recording.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            recordingURL = url
            isRecording = true
        } catch {
            debugPrint("[DemoChatView] Recording failed: \(error)")
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false

        guard let url = recordingURL else { return }
        startSTTTranscription(audioURL: url)
    }

    func startSTTTranscription(audioURL: URL, label: String = "Audio Recording") {
        messages.append(DisplayMessage(role: .user, content: "[\(label)]"))
        let generationID = beginGeneration(status: .scaffoldListening)

        generationTask = Task(priority: .userInitiated) { @MainActor in
            await Task.yield()
            do {
                var fullText = ""
                var tokenCount = 0
                for try await event in aiManager.transcribeStream(audioURL: audioURL) {
                    try Task.checkCancellation()
                    guard isActiveGeneration(generationID) else { throw CancellationError() }
                    switch event {
                    case .token(let text):
                        fullText += text
                        currentResponse = fullText
                        tokenCount += 1
                        updateActivityOutputTokens(tokenCount)
                    case .result(let result):
                        if !result.text.isEmpty {
                            fullText = result.text
                            currentResponse = fullText
                            updateActivityOutputTokens(max(1, fullText.split(separator: " ").count))
                        }
                    case .info:
                        break
                    }
                }
                try Task.checkCancellation()
                if isActiveGeneration(generationID) {
                    messages.append(DisplayMessage(
                        role: .assistant,
                        content: fullText.isEmpty ? "(No speech detected)" : fullText
                    ))
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
