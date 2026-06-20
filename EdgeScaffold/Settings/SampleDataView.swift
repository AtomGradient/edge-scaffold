// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeData

struct SampleDataView: View {
    @AppStorage(ScaffoldSampleDomainRegistry.selectedDomainDefaultsKey)
    private var selectedDomainRawValue = ScaffoldSampleDomainRegistry.defaultDomain.id.rawValue

    @State private var stats: ScaffoldSampleDomainSeedResult?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        List {
            SampleDomainPickerSection(
                selectedDomainRawValue: $selectedDomainRawValue,
                onDomainActivated: {
                    refreshStats()
                }
            )

            Section {
                Label("Demo Data · Synthetic", systemImage: "shippingbox.fill")
                    .font(.headline)
                    .foregroundStyle(.teal)
                Text("A fictional \(selectedDomain.displayName.lowercased()) pack used to demonstrate EdgeData classification, read-only tools, RPP profile learning, and Neural Imprint A/B without importing dogfood business data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Dataset") {
                infoRow("Domain", selectedDomain.displayName)
                infoRow("Resource", "\(selectedDomain.resourceName).json")
                infoRow("Records", "\(stats?.sampleRecords ?? 0)")
                infoRow("Namespace", selectedDomain.namespace)
                infoRow("Schema", selectedDomain.schemaName)
            }

            Section("EdgeData") {
                infoRow("Classified", "\(stats?.classified ?? 0)")
                infoRow("Raw pending", "\(stats?.rawUnclassified ?? 0)")
                infoRow("Total", "\(stats?.total ?? 0)")
            }

            Section {
                Button {
                    seedRawFacts()
                } label: {
                    Label("Seed Raw Demo Records", systemImage: "tray.and.arrow.down.fill")
                }
                .disabled(isWorking || !EdgeDataBootstrap.isReady)

                Button {
                    seedClassifiedFacts()
                } label: {
                    Label("Seed Classified Demo Facts", systemImage: "checkmark.seal.fill")
                }
                .disabled(isWorking || !EdgeDataBootstrap.isReady)

                if isWorking {
                    HStack {
                        ProgressView()
                        Text("Writing sample data...")
                            .foregroundStyle(.secondary)
                    }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Seed")
            } footer: {
                Text("Raw records exercise ClassificationDaemon. Classified facts give developers an immediate RPP and tool-query path without waiting for all sample records to be classified on device.")
            }

            Section("Next") {
                NavigationLink("Run Classification Review") {
                    ClassificationDemoView()
                }
                NavigationLink("Run User Profile (RPP)") {
                    RPPSelfLearningView()
                }
                NavigationLink("Open Neural Imprint A/B Smoke") {
                    PersonaABTestView()
                }
            }
        }
        .navigationTitle("Sample Data")
        .task { refreshStats() }
    }

    private func seedRawFacts() {
        Task {
            await performSeed("raw") {
                try selectedDomain.seedRawFacts()
            }
        }
    }

    private func seedClassifiedFacts() {
        Task {
            await performSeed("classified") {
                try selectedDomain.seedClassifiedFacts()
            }
        }
    }

    @MainActor
    private func performSeed(
        _ label: String,
        action: () throws -> ScaffoldSampleDomainSeedResult
    ) async {
        isWorking = true
        statusMessage = nil
        errorMessage = nil
        do {
            let result = try action()
            stats = result
            statusMessage = "Seeded \(result.writtenThisRun) \(label) records. Total facts: \(result.total)."
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func refreshStats() {
        guard EdgeDataBootstrap.isReady else { return }
        stats = try? selectedDomain.stats()
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.caption.monospaced())
        }
    }
}

struct SampleDomainPickerSection: View {
    @Binding var selectedDomainRawValue: String
    let onDomainActivated: () -> Void

    @State private var isSwitching = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var selectedDomain: ScaffoldSampleDomainDescriptor {
        ScaffoldSampleDomainRegistry.descriptor(forRawValue: selectedDomainRawValue)
    }

    var body: some View {
        Section {
            Picker("Domain", selection: $selectedDomainRawValue) {
                ForEach(ScaffoldSampleDomainRegistry.all) { domain in
                    Text(domain.displayName).tag(domain.id.rawValue)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedDomain.displayName)
                    .font(.subheadline.bold())
                Text(selectedDomain.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(selectedDomain.toolProvider.toolNames.count) tools · \(selectedDomain.namespace)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            if isSwitching {
                HStack {
                    ProgressView()
                    Text("Switching sample domain...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Sample Domain")
        } footer: {
            Text("Changing domains clears scaffold sample facts, seeds raw records for the selected domain, and replaces ToolRegistry with only that domain's read-only tools.")
        }
        .onChange(of: selectedDomainRawValue) { _, rawValue in
            activateDomain(rawValue)
        }
    }

    private func activateDomain(_ rawValue: String) {
        guard !isSwitching else { return }
        isSwitching = true
        statusMessage = nil
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let domain = ScaffoldSampleDomainRegistry.descriptor(forRawValue: rawValue)
                let displayName = domain.displayName
                let result = try ScaffoldSampleDomainRegistry.switchToDomain(rawValue: rawValue)
                let written = result?.writtenThisRun ?? 0
                await MainActor.run {
                    statusMessage = "Switched to \(displayName); seeded \(written) raw records."
                    onDomainActivated()
                    isSwitching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSwitching = false
                }
            }
        }
    }
}

struct SampleDomainMiniHeader: View {
    let domain: ScaffoldSampleDomainDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(domain.displayName, systemImage: "shippingbox.fill")
                .font(.subheadline.bold())
            Text(domain.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(domain.namespace) · \(domain.toolProvider.toolNames.count) tools")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
