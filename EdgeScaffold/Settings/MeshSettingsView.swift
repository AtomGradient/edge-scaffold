// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeMesh

struct MeshSettingsView: View {
    @EnvironmentObject private var meshManager: MeshManager

    @State private var showPairingSheet = false
    @State private var revokeTarget: TrustStore.TrustedPeer?
    @State private var deleteTarget: TrustStore.TrustedPeer?
    @State private var isReconciling = false
    @State private var tapPairPin: String?
    @State private var tapPairHostName: String?
    @State private var tapPairError: String?
    @State private var tapPairInFlight = false
    @State private var meshActionError: String?

    var body: some View {
        List {
            Section {
                Toggle("EdgeMesh", isOn: Binding(
                    get: { meshManager.isEnabled },
                    set: { _ in meshManager.toggle() }
                ))

                Toggle("Joint Inference", isOn: $meshManager.jointInferenceEnabled)
                    .disabled(!meshManager.isEnabled)

                HStack {
                    Image(systemName: meshManager.canUseJointInference ? "arrow.triangle.branch" : "arrow.triangle.branch.circle")
                        .foregroundStyle(meshManager.canUseJointInference ? .indigo : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meshManager.canUseJointInference ? "Mac route ready" : "Mac route unavailable")
                            .font(.subheadline)
                        Text(meshManager.lastJointInferenceStatus ?? "Pair and connect an EdgeStudio host to stream chat from the Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if meshManager.engine.isDiscovering {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Discovering nearby devices...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let applyStatus = meshManager.latestHaloCapsuleApplyStatus {
                    HaloCapsuleApplyStatusBadge(payload: applyStatus)
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Enable EdgeMesh to discover nearby devices. Joint Inference routes LLM chat to a trusted EdgeStudio host while preserving the same streaming chat UI.")
            }

            trustedDevicesSection

            if meshManager.isEnabled {
                Section {
                    if meshManager.engine.peers.isEmpty {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                            Text("No devices found yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(meshManager.engine.peers) { peer in
                            let isUntrusted = peer.trustStatus != .trusted
                            Button {
                                guard isUntrusted else { return }
                                requestTapPair(with: peer)
                            } label: {
                                HStack {
                                    PeerRow(peer: peer)
                                    if isUntrusted {
                                        Image(systemName: "link.badge.plus")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!isUntrusted || tapPairInFlight)
                        }
                    }
                } header: {
                    Text("Nearby Devices (\(meshManager.engine.peers.count))")
                } footer: {
                    Text("Tap an untrusted device to request pairing. A 6-character PIN appears on both screens — confirm it matches before approving on the Mac.")
                }

                Section("Topology") {
                    let topo = meshManager.engine.topology
                    HStack {
                        TierBadge(tier: "T0", count: topo.tier0.count, color: .blue)
                        TierBadge(tier: "T1", count: topo.tier1.count, color: .green)
                        TierBadge(tier: "T2", count: topo.tier2.count, color: .purple)
                    }
                    .padding(.vertical, 4)

                    Text("T0: Data Collection  |  T1: Daily Inference  |  T2: Panoramic Insight")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let best = meshManager.bestInferenceNode {
                    Section("Recommended Node") {
                        PeerRow(peer: best)
                    }
                }
            }
        }
        .navigationTitle("EdgeMesh")
        .refreshable {
            isReconciling = true
            await meshManager.reconcilePeers()
            isReconciling = false
        }
        .task {
            await meshManager.setupSecurityIfNeeded()
            meshManager.refreshState()
            await meshManager.reconcilePeers()
        }
        .sheet(isPresented: $showPairingSheet) {
            PairingSheet()
                .environmentObject(meshManager)
        }
        .confirmationDialog(
            "Revoke this device?",
            isPresented: Binding(
                get: { revokeTarget != nil },
                set: { if !$0 { revokeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: revokeTarget
        ) { peer in
            Button("Revoke \(peer.displayName)", role: .destructive) {
                Task {
                    do {
                        try await meshManager.revoke(peerId: peer.peerId)
                    } catch {
                        debugPrint("[MeshSettings] revoke failed: \(error)")
                        meshActionError = error.localizedDescription
                    }
                }
                revokeTarget = nil
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: { _ in
            Text("Future mTLS connections from this device will be rejected. The peer can re-pair later.")
        }
        .confirmationDialog(
            "Delete this device?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { peer in
            Button("Delete \(peer.displayName)", role: .destructive) {
                Task {
                    do {
                        try await meshManager.deletePeer(peerId: peer.peerId)
                    } catch {
                        debugPrint("[MeshSettings] delete failed: \(error)")
                        meshActionError = error.localizedDescription
                    }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("This permanently removes the device from this phone's trust store. Re-pairing requires scanning a fresh QR or PIN.")
        }
        .alert(
            "EdgeMesh action failed",
            isPresented: Binding(
                get: { meshActionError != nil },
                set: { if !$0 { meshActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { meshActionError = nil }
        } message: {
            Text(meshActionError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { tapPairPin != nil },
            set: { if !$0 { tapPairPin = nil; tapPairHostName = nil } }
        )) {
            TapPairPinSheet(
                pin: tapPairPin ?? "",
                hostName: tapPairHostName ?? "Mac",
                onDismiss: { tapPairPin = nil; tapPairHostName = nil }
            )
        }
        .alert("Pairing request failed",
               isPresented: Binding(
                   get: { tapPairError != nil },
                   set: { if !$0 { tapPairError = nil } }
               ),
               actions: { Button("OK") { tapPairError = nil } },
               message: { Text(tapPairError ?? "") })
    }

    private func requestTapPair(with peer: MeshNode) {
        tapPairInFlight = true
        Task {
            defer { tapPairInFlight = false }
            do {
                let result = try await meshManager.requestPairing(with: peer)
                tapPairPin = result.pin
                tapPairHostName = peer.displayName

                let hostSnapshot = peer
                let nonce = result.nonce
                let ttl = result.ttl_seconds
                let deadline = Date().addingTimeInterval(TimeInterval(ttl))
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if tapPairPin == nil { return }
                    let state = (try? await meshManager.pairStatusPublic(nonce: nonce, host: hostSnapshot)) ?? "unknown"
                    if state == "approved" {
                        do {
                            let httpPort = hostSnapshot.httpPort ?? 18842
                            let payload = try await meshManager.exchangePinForPayload(
                                pin: result.pin,
                                host: hostSnapshot.endpoint.host,
                                httpPort: httpPort
                            )
                            _ = try await meshManager.completePairing(with: payload)
                            tapPairPin = nil
                            tapPairHostName = nil
                        } catch {
                            tapPairError = "Pair failed: \(error.localizedDescription)"
                            tapPairPin = nil
                        }
                        return
                    }
                    if state == "expired" || state == "unknown" {
                        tapPairError = "Pairing session expired. Please try again."
                        tapPairPin = nil
                        return
                    }
                }
                tapPairPin = nil
                tapPairError = "No response from the Mac within \(ttl)s."
            } catch {
                tapPairError = error.localizedDescription
            }
        }
    }


    @ViewBuilder
    private var trustedDevicesSection: some View {
        Section {
            if meshManager.trustedPeers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No paired devices yet")
                            .font(.subheadline)
                        Text("Add your Mac running Edge Studio to start syncing.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(meshManager.trustedPeers, id: \.peerId) { peer in
                    TrustedPeerRow(peer: peer)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if peer.revoked {
                                Button(role: .destructive) {
                                    deleteTarget = peer
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } else {
                                Button(role: .destructive) {
                                    revokeTarget = peer
                                } label: {
                                    Label("Revoke", systemImage: "xmark.shield")
                                }
                            }
                        }
                }
            }

            Button {
                showPairingSheet = true
            } label: {
                Label("Add Device", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Trusted Devices (\(meshManager.trustedPeers.count))")
                Spacer()
                if !meshManager.isSecurityReady {
                    Text("Security not ready")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            if let err = meshManager.lastSecurityError {
                Text("Security init failed: \(err)")
                    .foregroundStyle(.red)
            } else {
                Text("Paired peers are trusted via mTLS certificate pinning. Revoke any device to block future connections.")
            }
        }
    }
}


private struct PeerRow: View {
    let peer: MeshNode

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(peer.deviceProfile.chipName)
                    Text("\(peer.deviceProfile.totalRAMGB) GB")
                    if peer.deviceProfile.bandwidthGBs > 0 {
                        Text(String(format: "%.0f GB/s", peer.deviceProfile.bandwidthGBs))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(peer.capability.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(capabilityColor.opacity(0.1))
                .foregroundStyle(capabilityColor)
                .clipShape(Capsule())
        }
    }

    private var iconName: String {
        switch peer.capability {
        case .inference: return "cpu"
        case .data: return "antenna.radiowaves.left.and.right"
        case .both: return "desktopcomputer"
        }
    }

    private var iconColor: Color {
        switch peer.deviceProfile.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private var capabilityColor: Color {
        switch peer.capability {
        case .inference: return .blue
        case .data: return .orange
        case .both: return .purple
        }
    }
}

private struct TierBadge: View {
    let tier: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(tier)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text("\(count)")
                .font(.title3.bold())
            Text("nodes")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct HaloCapsuleApplyStatusBadge: View {
    let payload: HaloCapsuleApplyStatusPayload

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Capsule \(payload.status.rawValue.capitalized)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(shortID(payload.capsuleID))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(payload.status.rawValue)
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
        }
    }

    private var detailText: String {
        if payload.status == .failed, let errorCode = payload.errorCode, !errorCode.isEmpty {
            return "Error \(errorCode)"
        }
        if let prefixTokenCount = payload.prefixTokenCount {
            return "\(prefixTokenCount) prefix tokens"
        }
        return "Transfer \(shortID(payload.transferID))"
    }

    private var iconName: String {
        switch payload.status {
        case .received:
            return "arrow.down.circle.fill"
        case .applied:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch payload.status {
        case .received:
            return .blue
        case .applied:
            return .green
        case .failed:
            return .red
        }
    }

    private func shortID(_ value: String) -> String {
        value.count > 10 ? String(value.prefix(10)) : value
    }
}

private struct TapPairPinSheet: View {
    let pin: String
    let hostName: String
    let onDismiss: () -> Void
    @EnvironmentObject private var meshManager: MeshManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue.gradient)
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text("Pairing with")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(hostName)
                        .font(.title3.bold())
                }

                VStack(spacing: 8) {
                    Text("PIN CODE")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tracking(2)
                    Text(pin)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Open Edge Studio on the Mac.", systemImage: "1.circle.fill")
                    Label("Confirm the same 6-character PIN appears.", systemImage: "2.circle.fill")
                    Label("Tap Approve on the Mac.", systemImage: "3.circle.fill")
                }
                .font(.callout)
                .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Confirm PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }
}

private struct TrustedPeerRow: View {
    let peer: TrustStore.TrustedPeer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peer.revoked ? "xmark.shield.fill" : iconName(for: peer.role))
                .foregroundStyle(peer.revoked ? .red : roleColor(for: peer.role))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .strikethrough(peer.revoked)

                HStack(spacing: 6) {
                    Text(peer.role.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(roleColor(for: peer.role))
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text("Paired \(peer.pairedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if peer.revoked {
                Text("Revoked")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1))
                    .clipShape(Capsule())
            } else if peer.lastSeenAt != nil {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func iconName(for role: String) -> String {
        switch role {
        case "brain":  return "brain.head.profile"
        case "sensor": return "iphone.radiowaves.left.and.right"
        default:       return "laptopcomputer"
        }
    }

    private func roleColor(for role: String) -> Color {
        switch role {
        case "brain":  return .purple
        case "sensor": return .blue
        default:       return .indigo
        }
    }
}
