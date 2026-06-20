// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData

struct CorrectionLearningView: View {
    @StateObject private var personalization = PersonalizationManager.shared
    @ObservedObject private var rppManager = RPPSelfLearningManager.shared

    @State private var classifiedFactCount = 0
    @State private var rawUnclassifiedCount = 0
    @State private var classificationCorrectionCount = 0
    @State private var trainingEventCount = 0
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            Section {
                Label("Correction Learning", systemImage: "checklist.checked")
                    .font(.headline)
                    .foregroundStyle(.teal)
                Text("Corrections are evidence for the next profile refresh. EdgeScaffold keeps the business mapping local and feeds stable signals into RPP instead of writing raw correction logs directly into Neural Imprint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Signals") {
                infoRow("Chat Feedback", "\(personalization.feedbackCount)")
                infoRow("Chat Corrections", "\(personalization.correctionCount)")
                infoRow("Classification Corrections", "\(classificationCorrectionCount)")
                infoRow("Classified Facts", "\(classifiedFactCount)")
                infoRow("Raw Pending", "\(rawUnclassifiedCount)")
                infoRow("Training Events", "\(trainingEventCount)")
            }

            Section("Review") {
                NavigationLink {
                    ClassificationDemoView()
                } label: {
                    Label("Open Classification Review", systemImage: "tag.fill")
                }
                NavigationLink {
                    SampleDataView()
                } label: {
                    Label("Seed or Inspect Sample Data", systemImage: "shippingbox.fill")
                }
            }

            Section("Relearn") {
                if canLearnAgain {
                    Label(refreshReadinessText, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Run User Profile Learning after you have classified facts or correction signals.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    RPPSelfLearningView()
                } label: {
                    Label("Open User Profile Learning", systemImage: "brain.head.profile.fill")
                }
            }

            Section("Maintenance") {
                Button(role: .destructive) {
                    personalization.clearFeedback()
                    refreshStats()
                } label: {
                    Label("Clear Feedback and Corrections", systemImage: "trash")
                }
                .disabled(personalization.feedbackCount == 0 && personalization.correctionCount == 0)
            }
        }
        .navigationTitle("Correction Learning")
        .task {
            refreshStats()
        }
    }

    private var canLearnAgain: Bool {
        rppManager.lastOutput != nil
            && (classificationCorrectionCount > 0
                || personalization.correctionCount > 0
                || personalization.feedbackCount > 0)
    }

    private var refreshReadinessText: String {
        let corrections = classificationCorrectionCount + personalization.correctionCount
        return "Profile can learn again: \(corrections) corrections, \(classifiedFactCount) classified facts."
    }

    private func refreshStats() {
        guard EdgeDataBootstrap.isReady else { return }
        classifiedFactCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .classifiedOnly
        )) ?? 0
        rawUnclassifiedCount = (try? Edge.countFacts(
            namespace: selectedDomain.namespace,
            status: .rawUnclassified
        )) ?? 0
        let facts = (try? Edge.queryFacts(
            namespace: selectedDomain.namespace,
            status: .all,
            limit: 1_000
        )) ?? []
        classificationCorrectionCount = facts.filter { $0.classificationCorrectedAt != nil }.count
        trainingEventCount = EdgeDataBootstrap.trainingSink?.eventStoreCount() ?? 0
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
