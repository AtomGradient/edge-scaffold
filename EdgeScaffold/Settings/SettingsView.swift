// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var aiManager: AIManager

    var body: some View {
        NavigationStack {
            List {
                AIEngineSection()

                Section("Mesh Network") {
                    NavigationLink {
                        MeshSettingsView()
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.indigo)
                            Text("EdgeMesh")
                        }
                    }
                }

                AIPersonalizationSection()

                Section("Device") {
                    NavigationLink("Device Report") {
                        DeviceReportView()
                    }
                }

                if ScaffoldConfig.enableSustainability {
                    Section("Sustainability") {
                        NavigationLink {
                            SustainabilityView()
                        } label: {
                            HStack {
                                Image(systemName: "leaf")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text("Environmental Impact")
                                    Text(String(format: "$%.2f saved", CarbonSavingsManager.shared.totalCostSaved))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Storage") {
                    NavigationLink("Cache Management") {
                        CacheManagerView()
                    }
                }

                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text(ScaffoldConfig.appName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Runtime")
                        Spacer()
                        Text("EdgeKit")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
