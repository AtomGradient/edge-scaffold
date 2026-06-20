// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeMesh

final class AppSummarizer: MeshSummarizable {

    let domain: String

    private let chatStats: ChatStatisticsProvider

    init(domain: String = ScaffoldConfig.appName, chatStats: ChatStatisticsProvider = ChatStatistics.shared) {
        self.domain = domain
        self.chatStats = chatStats
    }


    func summarize(days: Int) -> MeshSummary {
        let stats = chatStats.statistics(forDays: days)

        var metrics: [MeshSummary.Metric] = []
        var trends: [MeshSummary.Trend] = []
        var alerts: [MeshSummary.Alert] = []

        metrics.append(MeshSummary.Metric(
            name: "daily_messages",
            mean: stats.avgDailyMessages,
            min: stats.minDailyMessages,
            max: stats.maxDailyMessages,
            stdDev: stats.stdDevDailyMessages,
            sampleCount: stats.totalDays
        ))

        metrics.append(MeshSummary.Metric(
            name: "avg_response_tokens",
            mean: stats.avgResponseTokens,
            min: stats.minResponseTokens,
            max: stats.maxResponseTokens,
            stdDev: 0,
            sampleCount: stats.totalMessages
        ))

        metrics.append(MeshSummary.Metric(
            name: "positive_feedback_ratio",
            mean: stats.positiveFeedbackRatio,
            min: 0,
            max: 1,
            stdDev: 0,
            sampleCount: stats.totalFeedback
        ))

        if stats.totalDays >= 3 {
            let trend: MeshSummary.Trend.Direction = {
                if stats.recentVsOlderRatio > 1.1 { return .increasing }
                if stats.recentVsOlderRatio < 0.9 { return .decreasing }
                return .stable
            }()
            trends.append(MeshSummary.Trend(
                metric: "daily_messages",
                direction: trend,
                magnitude: abs(stats.recentVsOlderRatio - 1.0),
                confidence: min(Double(stats.totalDays) / 7.0, 1.0)
            ))
        }

        if stats.totalFeedback >= 5 && stats.positiveFeedbackRatio < 0.5 {
            alerts.append(MeshSummary.Alert(
                level: .warning,
                message: "Low user satisfaction — consider model retraining",
                metric: "positive_feedback_ratio",
                value: stats.positiveFeedbackRatio,
                threshold: 0.5
            ))
        }

        return MeshSummary(
            domain: domain,
            periodDays: days,
            metrics: metrics,
            trends: trends,
            alerts: alerts
        )
    }
}


protocol ChatStatisticsProvider {
    func statistics(forDays days: Int) -> ChatStats
}

struct ChatStats {
    var totalDays: Int = 0
    var totalMessages: Int = 0
    var totalFeedback: Int = 0

    var avgDailyMessages: Double = 0
    var minDailyMessages: Double = 0
    var maxDailyMessages: Double = 0
    var stdDevDailyMessages: Double = 0

    var avgResponseTokens: Double = 0
    var minResponseTokens: Double = 0
    var maxResponseTokens: Double = 0

    var positiveFeedbackRatio: Double = 0
    var recentVsOlderRatio: Double = 1.0  // > 1 = increasing engagement
}

final class ChatStatistics: ChatStatisticsProvider {

    static let shared = ChatStatistics()

    func statistics(forDays days: Int) -> ChatStats {
        let defaults = UserDefaults.standard

        let totalTokens = defaults.integer(forKey: "ai_total_tokens")
        let totalMessages = max(defaults.integer(forKey: "ai_total_messages"), 1)
        let goodFeedback = defaults.integer(forKey: "ai_good_feedback")
        let totalFeedback = defaults.integer(forKey: "ai_total_feedback")

        let avgTokensPerMsg = Double(totalTokens) / Double(totalMessages)
        let feedbackRatio = totalFeedback > 0 ? Double(goodFeedback) / Double(totalFeedback) : 0

        return ChatStats(
            totalDays: min(days, 30),
            totalMessages: totalMessages,
            totalFeedback: totalFeedback,
            avgDailyMessages: Double(totalMessages) / Double(max(days, 1)),
            minDailyMessages: 0,
            maxDailyMessages: Double(totalMessages),  // simplified
            stdDevDailyMessages: 0,
            avgResponseTokens: avgTokensPerMsg,
            minResponseTokens: 0,
            maxResponseTokens: avgTokensPerMsg * 2,  // simplified
            positiveFeedbackRatio: feedbackRatio,
            recentVsOlderRatio: 1.0  // simplified — would need daily breakdown
        )
    }
}
