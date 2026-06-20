// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import UIKit
import UserNotifications
import EdgeInference

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        EdgeDataBootstrap.setup()

        if ScaffoldDomainSmokeRunner.shouldRun {
            ScaffoldDomainSmokeRunner.runAndExit()
            return true
        }
        if ScaffoldDomainABSmokeRunner.shouldRun {
            ScaffoldDomainABSmokeRunner.runAndExit()
            return true
        }
        if ScaffoldFeedbackSmokeRunner.shouldRun {
            ScaffoldFeedbackSmokeRunner.runAndExit()
            return true
        }
        if ScaffoldSnapshotSmokeRunner.shouldRun {
            ScaffoldSnapshotSmokeRunner.runAndExit()
            return true
        }

        Self.requestNotificationAuthorizationIfNeeded()
        return true
    }

    static func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        NSLog("[AppDelegate] requestAuthorization failed: \(error.localizedDescription)")
                    } else {
                        NSLog("[AppDelegate] notification authorization granted=\(granted)")
                    }
                }
            case .denied, .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }
}
