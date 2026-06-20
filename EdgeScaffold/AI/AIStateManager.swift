// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference

@MainActor
final class AIStateManager: ObservableObject {

    static let shared = AIStateManager()

    private let defaults = UserDefaults.standard


    private enum Keys {
        static let aiEnabled = "ai_enabled"
        static let modelDownloaded = "model_downloaded"
        static let lastLoadedModelID = "last_loaded_model_id"
        static let totalTokensGenerated = "total_tokens_generated"
    }


    @Published var isAIEnabled: Bool {
        didSet { defaults.set(isAIEnabled, forKey: Keys.aiEnabled) }
    }

    @Published var isModelDownloaded: Bool {
        didSet { defaults.set(isModelDownloaded, forKey: Keys.modelDownloaded) }
    }

    @Published var totalTokensGenerated: Int {
        didSet { defaults.set(totalTokensGenerated, forKey: Keys.totalTokensGenerated) }
    }


    var selectedConfig: ModelConfig {
        if let config = ModelConfig.find(modelID: ScaffoldConfig.modelID) {
            return config
        }
        return ModelConfig.config(for: .standard)
    }


    private init() {
        self.isAIEnabled = defaults.bool(forKey: Keys.aiEnabled)
        self.isModelDownloaded = defaults.bool(forKey: Keys.modelDownloaded)
        self.totalTokensGenerated = defaults.integer(forKey: Keys.totalTokensGenerated)

        if !defaults.bool(forKey: "ai_initialized") {
            isAIEnabled = true
            defaults.set(true, forKey: "ai_initialized")
        }
    }


    func recordTokens(_ count: Int) {
        totalTokensGenerated += count
    }

    func setLastLoadedModel(_ id: String) {
        defaults.set(id, forKey: Keys.lastLoadedModelID)
    }

    var lastLoadedModelID: String? {
        defaults.string(forKey: Keys.lastLoadedModelID)
    }
}
