// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeInference
import EdgeModelKit
import EdgeUI

@main
struct EdgeScaffoldApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var aiManager = AIManager.shared
    @StateObject private var meshManager = MeshManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    HomeView()
                        .environmentObject(aiManager)
                        .environmentObject(meshManager)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                        .environmentObject(aiManager)
                        .environmentObject(meshManager)
                }
            }
            .task {
                await meshManager.setupSecurityIfNeeded()
            }
            .modifier(HaloCapsuleOfferAlertModifier(meshManager: meshManager))
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                backgroundTask = Task {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        aiManager.unloadModel()
                    }
                }
            case .active:
                backgroundTask?.cancel()
                backgroundTask = nil
                if !aiManager.isModelLoaded && aiManager.stateManager.isAIEnabled {
                    Task { await aiManager.handleForegrounding() }
                }
            default:
                break
            }
        }
    }
}

private struct HaloCapsuleOfferAlertModifier: ViewModifier {
    @ObservedObject var meshManager: MeshManager
    @ObservedObject private var diagnostics = EdgeDiagnostics.shared

    func body(content: Content) -> some View {
        content.alert(
            "Apply Neural Imprint capsule?",
            isPresented: Binding(
                get: { meshManager.pendingHaloCapsuleOffer != nil },
                set: { _ in }
            )
        ) {
            if let offer = meshManager.pendingHaloCapsuleOffer {
                Button("Reject", role: .destructive) {
                    meshManager.rejectPendingHaloCapsuleOffer(id: offer.id)
                }
                Button("Accept") {
                    meshManager.acceptPendingHaloCapsuleOffer(id: offer.id)
                }
            }
        } message: {
            if let offer = meshManager.pendingHaloCapsuleOffer {
                if diagnostics.isDetailedMetricsEnabled {
                    Text("""
                    Source: \(offer.sourceDisplayName)
                    Model: \(offer.baseModelID)
                    Prefix tokens: \(offer.prefixTokenCount)
                    Artifact: \(offer.artifactSHA12)
                    """)
                } else {
                    Text("""
                    Source: \(offer.sourceDisplayName)
                    Model: \(offer.baseModelID)
                    Neural Imprint capsule is ready to apply.
                    """)
                }
            } else {
                Text("")
            }
        }
    }
}
