// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI

struct SustainabilityView: View {
    @StateObject private var carbon = CarbonSavingsManager.shared

    var body: some View {
        List {
            Section("Environmental Impact") {
                statRow("Total Tokens Processed", "\(carbon.totalTokens)")
                statRow("Cost Saved vs Cloud", String(format: "$%.2f", carbon.totalCostSaved))
                statRow("CO\u{2082} Saved", String(format: "%.4f kg", carbon.totalCO2SavedKg))
                statRow("Days of On-Device AI", "\(carbon.daysSinceFirstUse())")
            }

            Section("Equivalents") {
                HStack {
                    Image(systemName: "tree")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(String(format: "%.3f trees", carbon.equivalentTrees()))
                            .font(.headline)
                        Text("CO\u{2082} absorption per year")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Image(systemName: "car")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(String(format: "%.2f km", carbon.equivalentKmDriven()))
                            .font(.headline)
                        Text("Car emissions avoided")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works")
                        .font(.headline)
                    Text("By running AI locally on your device instead of in the cloud, \(ScaffoldConfig.appName) reduces carbon emissions by approximately 80%. Cloud AI requires massive data centers that consume significant energy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sustainability")
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }
}
