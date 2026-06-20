// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference

struct DeviceReportView: View {
    @State private var report: DeviceCapabilityChecker.Report?
    @State private var isRunningBenchmark = false

    var body: some View {
        List {
            if let report {
                Section("Hardware") {
                    infoRow("GPU", deviceLabel(report.profile))
                    infoRow("Metal Family", "\(report.profile.metalFamilyTier)")
                    infoRow("Total RAM", "\(report.profile.totalRAMGB) GB")
                    infoRow("Available RAM", "\(report.profile.availableRAMGB) GB")
                    infoRow("Free Storage", String(format: "%.1f GB", report.freeStorageGB))
                }

                Section("Power") {
                    infoRow("Battery", String(format: "%.0f%%", report.batteryLevel * 100))
                    infoRow("Low Power Mode", report.isLowPowerMode ? "On" : "Off")
                    infoRow("Plugged In", report.isPluggedIn ? "Yes" : "No")
                    infoRow("Thermal State", thermalString(report.profile.thermalState))
                }

                if let iq = report.aiIQ {
                    Section("AI Performance") {
                        HStack {
                            Text("AI IQ")
                            Spacer()
                            Text("\(iq.iq)")
                                .font(.title2.bold().monospacedDigit())
                                .foregroundStyle(iqColor(iq.iq))
                            Text(iq.label)
                                .foregroundStyle(.secondary)
                        }
                        infoRow("Capacity", "\(Int(round(iq.capacityPct * 100)))%")
                        infoRow("Speed", "\(Int(round(iq.speedPct * 100)))%")
                        infoRow("Bandwidth Score", "\(iq.bandwidthScore)%")
                        infoRow("GPU Score", "\(iq.gpuScore)%")
                        infoRow("Compatibility", "\(iq.compatScore)%")
                    }
                }

                if let bench = report.benchmark {
                    Section("Benchmark") {
                        if bench.effectiveBandwidthGBs > 0 {
                            infoRow("Measured Bandwidth", String(format: "%.1f GB/s", bench.effectiveBandwidthGBs))
                        } else {
                            Text("Metal benchmark unavailable")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }

                Section {
                    Button {
                        isRunningBenchmark = true
                        Task {
                            self.report = await DeviceCapabilityChecker.evaluateWithBenchmark()
                            isRunningBenchmark = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Re-run Benchmark")
                        }
                    }
                    .disabled(isRunningBenchmark)
                }
            } else {
                ProgressView("Evaluating...")
            }
        }
        .navigationTitle("Device Report")
        .task {
            report = await DeviceCapabilityChecker.evaluateWithBenchmark()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func thermalString(_ state: DeviceProfile.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Warm"
        case .critical: "Hot"
        }
    }

    private func deviceLabel(_ profile: DeviceProfile) -> String {
        profile.metalDeviceName ?? "Metal Family \(profile.metalFamilyTier)"
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
}
