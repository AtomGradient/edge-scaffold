// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeSession
import EdgeUI

struct HomeView: View {
    @EnvironmentObject private var aiManager: AIManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared
    @StateObject private var meshManager = MeshManager.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        modelStatusCard
                            .padding(.horizontal)

                        quickActionsSection
                            .padding(.horizontal)

                        recentConversationsSection
                            .padding(.horizontal)

                        deviceInfoCard
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
                .navigationTitle("Home")
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(0)

            DemoChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
        .alert(
            "Mac 建议训练个性化模型",
            isPresented: Binding(
                get: { meshManager.pendingTrainingSuggestion != nil },
                set: { if !$0 { meshManager.dismissTrainingSuggestion() } }
            ),
            presenting: meshManager.pendingTrainingSuggestion
        ) { suggestion in
            Button("允许") {
                meshManager.acceptTrainingSuggestion()
            }
            Button("稍后再说", role: .cancel) {
                meshManager.dismissTrainingSuggestion()
            }
        } message: { suggestion in
            Text("自上次训练以来已积累 \(suggestion.newEventCount) 条新数据（阈值 \(suggestion.threshold)）。允许 Mac 为你训练一个更懂你的模型吗？训练期间你的 iPhone 可以正常使用。")
        }
    }


    private var modelStatusCard: some View {
        VStack(spacing: 0) {
            ChatTheme.userGradient
                .frame(height: 4)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))

            GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(ChatTheme.accent)
                        .symbolEffect(.pulse, options: .repeating.speed(0.3))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ScaffoldConfig.appName)
                            .font(.system(.headline, design: .rounded))
                        Text(ScaffoldConfig.appDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack {
                    Circle()
                        .fill(aiManager.isModelLoaded ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    Text(aiManager.isModelLoaded
                         ? (aiManager.loadedModelName ?? "Model Loaded")
                         : "No Model Loaded")
                        .font(.subheadline)
                    Spacer()

                    if aiManager.isModelLoaded {
                        Text(aiManager.modelCategory.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(categoryColor)
                            .clipShape(Capsule())
                    }
                }

                if aiManager.engineState == .loading {
                    ProgressView(value: aiManager.loadingProgress)
                        .progressViewStyle(.linear)
                }

                if aiManager.neuralImprintCacheStatus != nil {
                    Label(
                        "Neural Imprint active",
                        systemImage: "person.text.rectangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    .edgeDiagnosticTapGesture()
                } else if let error = aiManager.neuralImprintCacheError {
                    Label("Neural Imprint restore failed", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !aiManager.isModelLoaded && aiManager.stateManager.isAIEnabled {
                    Button {
                        Task { await aiManager.loadSelectedModel() }
                    } label: {
                        Text("Load Model")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ChatTheme.accent)
                }

                if diagnostics.isDetailedMetricsEnabled && aiManager.stateManager.totalTokensGenerated > 0 {
                    HStack {
                        Image(systemName: "text.word.spacing")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("Lifetime output · \(aiManager.stateManager.totalTokensGenerated) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            } // GroupBox
        } // VStack
    }


    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                quickActionButton(
                    icon: "bubble.left.and.bubble.right",
                    title: "Start Chat",
                    color: ChatTheme.accent
                ) {
                    selectedTab = 1
                }

                NavigationLink {
                    DeviceReportView()
                } label: {
                    quickActionLabel(
                        icon: "cpu",
                        title: "Device Report",
                        color: .purple
                    )
                }
            }
        }
    }

    private func quickActionButton(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            quickActionLabel(icon: icon, title: title, color: color)
        }
        .buttonStyle(.plain)
    }

    private func quickActionLabel(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }


    private var recentConversationsSection: some View {
        let recent = Array(ConversationStore.shared.conversations.prefix(3))
        return Group {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent Conversations")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("See All") { selectedTab = 1 }
                            .font(.caption)
                    }

                    VStack(spacing: 8) {
                        ForEach(recent) { conv in
                            Button {
                                selectedTab = 1
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conv.title)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text(conv.updatedAt, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(conv.messageCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }


    private var deviceInfoCard: some View {
        let report = DeviceCapabilityChecker.evaluate()
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "iphone")
                        .foregroundStyle(.green)
                    Text("Device")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }

                HStack {
                    Text("GPU")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(deviceLabel(report.profile))
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("Metal Family")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.profile.metalFamilyTier)")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("RAM")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.profile.totalRAMGB) GB")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("Recommended")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(report.recommendedTier.rawValue.capitalized)
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("Free Storage")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f GB", report.freeStorageGB))
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
        }
    }


    private var categoryColor: Color {
        switch aiManager.modelCategory {
        case .llm: .blue
        case .vlm: .purple
        case .tts: .green
        case .stt: .orange
        }
    }

    private func deviceLabel(_ profile: DeviceProfile) -> String {
        profile.metalDeviceName ?? "Metal Family \(profile.metalFamilyTier)"
    }
}
