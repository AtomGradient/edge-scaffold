// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeInference
#if canImport(UIKit)
import UIKit
#endif

struct DeviceCapabilityChecker {

    struct Report {
        let profile: DeviceProfile
        let recommendedTier: ModelTier
        let freeStorageGB: Double
        let batteryLevel: Float
        let isLowPowerMode: Bool
        let isPluggedIn: Bool
        let benchmark: DeviceBenchmark?
        let aiIQ: AIIQScorer.Score?
    }

    static func evaluate() -> Report {
        let profile = DeviceProfile.current
        let tier = ModelTierSelector.recommend(for: profile)

        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel
        let pluggedIn = device.batteryState == .charging || device.batteryState == .full
        #else
        let battery: Float = 1.0
        let pluggedIn = true
        #endif

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        return Report(
            profile: profile,
            recommendedTier: tier,
            freeStorageGB: freeStorage(),
            batteryLevel: battery,
            isLowPowerMode: lowPower,
            isPluggedIn: pluggedIn,
            benchmark: nil,
            aiIQ: nil
        )
    }


    static func freeStorage() -> Double {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return 0
        }
        return Double(free) / 1_073_741_824
    }

    static func hasSufficientStorage(for config: ModelConfig) -> Bool {
        freeStorage() > config.sizeGB * 1.2
    }


    static func evaluateWithBenchmark() async -> Report {
        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel
        let pluggedIn = device.batteryState == .charging || device.batteryState == .full
        #else
        let battery: Float = 1.0
        let pluggedIn = true
        #endif

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let bench = await DeviceBenchmark.run()
        let profile = bench.profile
        let tier = ModelTierSelector.recommend(for: profile)
        let iq = AIIQScorer.compute(benchmark: bench)

        return Report(
            profile: profile,
            recommendedTier: tier,
            freeStorageGB: freeStorage(),
            batteryLevel: battery,
            isLowPowerMode: lowPower,
            isPluggedIn: pluggedIn,
            benchmark: bench,
            aiIQ: iq
        )
    }
}
