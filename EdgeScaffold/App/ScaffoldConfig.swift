// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference

enum ScaffoldConfig {
    static let appName = "EdgeScaffold"
    static let appDescription = "AI-powered app built with EdgeKit"
    static let defaultSystemPrompt = "You are a helpful assistant."

    static let modelCategory: ModelCategory = .llm

    static let modelID: String = "Qwen3.5-9B-4bit"
    static let modelDisplayName: String = "Qwen3.5 9B (4bit)"
    static let modelSizeGB: Double = 5.0
    static let modelODRTag: String = "model"

    static let rppALibraryManifestResourceName: String = "rpp_a_library_manifest"
    static let rppModelFamily: String = "qwen3.5-9b"
    static let rppHiddenSize: Int = 4096
    static let rppLayerCount: Int = 32
    static let rppTargetLayer: Int = 11
    static let rppBatchNamingProgressDetailPrefix: String = "批量命名"
    static let defaultSampleDomainID: String = "finance"

    static let bundleModelName: String? = nil

    static let defaultTTSSpeaker: String? = nil

    static let defaultEnableThinking: Bool = false

    static let defaultTemperature: Float = 0.7
    static let defaultTopK: Int = 40
    static let defaultTopP: Float = 0.9
    static let defaultMaxTokens: Int = 1024

    static let enableSustainability = true
}
