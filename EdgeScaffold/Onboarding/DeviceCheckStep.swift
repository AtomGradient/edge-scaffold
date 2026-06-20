// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference

struct DeviceCheckStep: View {
    let onContinue: () -> Void

    @State private var report: DeviceCapabilityChecker.Report?
    @State private var isEvaluating = true
    @State private var statusText = "Evaluating hardware..."

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if isEvaluating {
                ProgressView()
                    .scaleEffect(1.5)
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if let report {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)

                Text("Device Ready")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 16) {
                    infoRow("GPU", deviceLabel(report.profile))
                    infoRow("Metal Family", "\(report.profile.metalFamilyTier)")
                    infoRow("Total RAM", "\(report.profile.totalRAMGB) GB")
                    infoRow("Available RAM", "\(report.profile.availableRAMGB) GB")
                    infoRow("Free Storage", String(format: "%.1f GB", report.freeStorageGB))
                    infoRow("Recommended", report.recommendedTier.rawValue.capitalized)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

                if let iq = report.aiIQ {
                    aiIQCard(iq)
                        .padding(.horizontal, 24)
                }
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(ChatTheme.userGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isEvaluating)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .task {
            statusText = "Running benchmark..."
            report = await DeviceCapabilityChecker.evaluateWithBenchmark()
            isEvaluating = false
        }
    }


    private func aiIQCard(_ score: AIIQScorer.Score) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("\(score.iq)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(iqColor(score.iq))
                    .contentTransition(.numericText())
                Text(score.label)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("AI IQ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 10) {
                capabilityBar("Capacity", pct: score.capacityPct, color: .blue)
                capabilityBar("Speed", pct: score.speedPct, color: .orange)
                capabilityBar("GPU", pct: Double(score.gpuScore) / 100, color: .purple)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func capabilityBar(_ label: String, pct: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(round(pct * 100)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray4))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * min(max(pct, 0), 1), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func iqColor(_ iq: Int) -> Color {
        switch iq {
        case ..<80:  return .gray
        case ..<100: return .blue
        case ..<120: return .green
        case ..<140: return .orange
        case ..<160: return .purple
        default:     return .red
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private func deviceLabel(_ profile: DeviceProfile) -> String {
        profile.metalDeviceName ?? "Metal Family \(profile.metalFamilyTier)"
    }
}
