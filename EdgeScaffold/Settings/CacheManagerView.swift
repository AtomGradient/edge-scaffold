// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeModelKit
import EdgeInference

struct CacheManagerView: View {
    @State private var totalSize: String = "Calculating..."
    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section("Model Cache") {
                HStack {
                    Text("Cache Size")
                    Spacer()
                    Text(totalSize)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Model Cache", role: .destructive) {
                    showClearConfirm = true
                }
            }
        }
        .navigationTitle("Cache")
        .task {
            updateSize()
        }
        .alert("Clear Cache?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                try? ModelCache.shared.evictAll()
                AIManager.shared.unloadModel()
                AIManager.shared.stateManager.isModelDownloaded = false
                updateSize()
            }
        } message: {
            Text("This will delete all downloaded AI models. You'll need to download them again.")
        }
    }

    private func updateSize() {
        let bytes = ModelCache.shared.totalCacheSize()
        if bytes == 0 {
            totalSize = "Empty"
        } else {
            totalSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
}
