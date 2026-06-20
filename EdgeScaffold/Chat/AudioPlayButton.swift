// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import AVFoundation

struct AudioPlayButton: View {
    let samples: [Float]
    let sampleRate: Int

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        Button {
            togglePlayback()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                Text(String(format: "%.1fs", Double(samples.count) / Double(sampleRate)))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }

        var data = Data()
        let numSamples = samples.count
        let dataSize = numSamples * 2

        data.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + dataSize).littleEndian
        data.append(Data(bytes: &fileSize, count: 4))
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        var chunkSize = UInt32(16).littleEndian; data.append(Data(bytes: &chunkSize, count: 4))
        var audioFormat = UInt16(1).littleEndian; data.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian; data.append(Data(bytes: &channels, count: 2))
        var sr = UInt32(sampleRate).littleEndian; data.append(Data(bytes: &sr, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian; data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian; data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian; data.append(Data(bytes: &bitsPerSample, count: 2))

        data.append(contentsOf: "data".utf8)
        var dataSizeLE = UInt32(dataSize).littleEndian; data.append(Data(bytes: &dataSizeLE, count: 4))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0).littleEndian
            data.append(Data(bytes: &int16, count: 2))
        }

        do {
            player = try AVAudioPlayer(data: data)
            player?.play()
            isPlaying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(samples.count) / Double(sampleRate) + 0.1) {
                isPlaying = false
            }
        } catch {
            debugPrint("[AudioPlayButton] Playback failed: \(error)")
        }
    }
}
