// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference

struct AIIQScorer {

    struct Score {
        let iq: Int
        let label: String
        let capacityPct: Double   // 0-1
        let speedPct: Double      // 0-1
        let bandwidthScore: Int   // 0-100
        let gpuScore: Int         // 0-100
        let compatScore: Int      // 0-100
        let recommendedTier: ModelTier
    }


    private struct ModelParam {
        let name: String
        let minMemGB: Double
        let goodMemGB: Double
    }

    private static let modelParams: [ModelParam] = [
        ModelParam(name: "Qwen3.5-0.8B",      minMemGB: 2,   goodMemGB: 4),
        ModelParam(name: "Qwen3.5-2B",         minMemGB: 4,   goodMemGB: 6),
        ModelParam(name: "Qwen3.5-4B",         minMemGB: 6,   goodMemGB: 8),
        ModelParam(name: "Qwen3.5-9B",         minMemGB: 7,   goodMemGB: 12),
        ModelParam(name: "Qwen3.5-27B",        minMemGB: 18,  goodMemGB: 32),
        ModelParam(name: "Qwen3.5-35B-A3B",    minMemGB: 22,  goodMemGB: 32),
        ModelParam(name: "Qwen3.5-122B-A10B",  minMemGB: 75,  goodMemGB: 96),
        ModelParam(name: "Qwen3.5-397B-A17B",  minMemGB: 245, goodMemGB: 256),
    ]


    private static let bwNorm: Double  = 819   // M3 Ultra bandwidth ceiling (GB/s)
    private static let metalFamilyNorm: Double = 10
    private static let iqMin = 58
    private static let iqMax = 185


    static func compute(benchmark: DeviceBenchmark) -> Score {
        let profile = benchmark.profile
        let memGB = Double(profile.totalRAMGB)

        let overhead: Double = deviceOverhead(totalRAMGB: profile.totalRAMGB)
        let usable = max(0, memGB - overhead)

        var compatRaw = 0.0
        for m in modelParams {
            let c = compatibility(minMem: m.minMemGB, goodMem: m.goodMemGB, totalMem: memGB, overhead: overhead)
            switch c {
            case .excellent: compatRaw += 2
            case .good:      compatRaw += 1
            case .marginal:  compatRaw += 0.3
            case .no:        break
            }
        }
        let compatPct = compatRaw / (Double(modelParams.count) * 2)
        let memPct = log(1 + usable) / log(1 + 509)  // 509 = 512GB - 3GB overhead
        let capacityPct = compatPct * 0.6 + memPct * 0.4

        let bw = benchmark.effectiveBandwidthGBs
        let metalTier = Double(profile.metalFamilyTier)
        let bwScore = min(1, log(1 + bw) / log(1 + bwNorm))
        let gpuScore = min(1, log(1 + metalTier) / log(1 + metalFamilyNorm))
        let speedPct = bwScore * 0.5 + gpuScore * 0.5

        let compatGate = min(1, compatPct * 5)

        let combined = capacityPct * 0.55 + speedPct * compatGate * 0.45
        let iq = max(iqMin, min(iqMax, Int(round(58 + combined * 127))))

        let label = iqLabel(iq)
        let tier = ModelTierSelector.recommend(for: profile)

        return Score(
            iq: iq,
            label: label,
            capacityPct: capacityPct,
            speedPct: speedPct,
            bandwidthScore: Int(round(bwScore * 100)),
            gpuScore: Int(round(gpuScore * 100)),
            compatScore: Int(round(compatPct * 100)),
            recommendedTier: tier
        )
    }


    private enum CompatLevel { case excellent, good, marginal, no }

    private static func compatibility(minMem: Double, goodMem: Double, totalMem: Double, overhead: Double) -> CompatLevel {
        let usable = totalMem - overhead
        if usable >= goodMem       { return .excellent }
        if usable >= minMem        { return .good }
        if usable >= minMem * 0.6  { return .marginal }
        return .no
    }

    private static func deviceOverhead(totalRAMGB: Int) -> Double {
        #if os(iOS)
        if totalRAMGB <= 8 { return 3 }    // iPhone
        return 2.5                          // iPad
        #else
        return 3                            // Mac
        #endif
    }

    private static func iqLabel(_ iq: Int) -> String {
        switch iq {
        case ..<80:  return "Basic"
        case ..<100: return "Capable"
        case ..<120: return "Smart"
        case ..<140: return "Advanced"
        case ..<160: return "Exceptional"
        default:     return "Elite"
        }
    }
}
