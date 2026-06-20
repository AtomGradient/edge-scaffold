// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation

@MainActor
final class CarbonSavingsManager: ObservableObject {
    static let shared = CarbonSavingsManager()

    private let inputTokenCostPer1M: Double = 4.25
    private let outputTokenCostPer1M: Double = 17.0

    private let cloudCO2PerToken: Double = 0.0000005
    private let localCO2PerToken: Double = 0.0000001

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let inputTokens = "carbon_total_input_tokens"
        static let outputTokens = "carbon_total_output_tokens"
        static let costSaved = "carbon_total_cost_saved"
        static let co2Saved = "carbon_total_co2_saved"
        static let firstUse = "carbon_first_use_date"
    }

    var totalInputTokens: Int { defaults.integer(forKey: Keys.inputTokens) }
    var totalOutputTokens: Int { defaults.integer(forKey: Keys.outputTokens) }
    var totalTokens: Int { totalInputTokens + totalOutputTokens }
    var totalCostSaved: Double { defaults.double(forKey: Keys.costSaved) }
    var totalCO2SavedKg: Double { defaults.double(forKey: Keys.co2Saved) }

    var firstUseDate: Date {
        if let date = defaults.object(forKey: Keys.firstUse) as? Date {
            return date
        }
        let date = Date()
        defaults.set(date, forKey: Keys.firstUse)
        return date
    }

    private init() {}

    func recordTokens(input: Int, output: Int) {
        let newInput = totalInputTokens + input
        let newOutput = totalOutputTokens + output
        defaults.set(newInput, forKey: Keys.inputTokens)
        defaults.set(newOutput, forKey: Keys.outputTokens)

        let inputCost = Double(input) / 1_000_000 * inputTokenCostPer1M
        let outputCost = Double(output) / 1_000_000 * outputTokenCostPer1M
        defaults.set(totalCostSaved + inputCost + outputCost, forKey: Keys.costSaved)

        let total = input + output
        let saved = Double(total) * (cloudCO2PerToken - localCO2PerToken)
        defaults.set(totalCO2SavedKg + saved, forKey: Keys.co2Saved)

        objectWillChange.send()
    }

    func equivalentTrees() -> Double {
        max(totalCO2SavedKg / 21.0, 0.001)
    }

    func equivalentKmDriven() -> Double {
        max(totalCO2SavedKg / 0.12, 0.01)
    }

    func daysSinceFirstUse() -> Int {
        max(Calendar.current.dateComponents([.day], from: firstUseDate, to: Date()).day ?? 0, 1)
    }

    func reset() {
        [Keys.inputTokens, Keys.outputTokens, Keys.costSaved, Keys.co2Saved, Keys.firstUse]
            .forEach { defaults.removeObject(forKey: $0) }
    }
}
