// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject private var aiManager: AIManager
    @State private var currentStep = 0

    var body: some View {
        TabView(selection: $currentStep) {
            WelcomeStep(onContinue: { currentStep = 1 })
                .tag(0)

            DeviceCheckStep(onContinue: { currentStep = 2 })
                .tag(1)

            DownloadStep(onComplete: { hasCompletedOnboarding = true })
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.easeInOut, value: currentStep)
    }
}


private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 72))
                .foregroundStyle(ChatTheme.accent)
                .symbolEffect(.breathe, options: .repeating.speed(0.3))

            Text(ScaffoldConfig.appName)
                .font(.system(.largeTitle, design: .rounded).bold())

            Text(ScaffoldConfig.appDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 14) {
                featureRow(icon: "lock.shield", text: "100% on-device AI")
                featureRow(icon: "bolt", text: "Powered by EdgeKit")
                featureRow(icon: "leaf", text: "Zero cloud dependency")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(ChatTheme.userGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(ChatTheme.accent)
                .frame(width: 32)
            Text(text)
                .font(.body)
            Spacer()
        }
    }
}
