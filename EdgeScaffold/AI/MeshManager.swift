// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import Combine
import CryptoKit
import EdgeHalo
import EdgeMesh
import EdgeInference
#if canImport(UIKit)
import UIKit
#endif

private struct RPPArtifactUploadError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct PersonaRPPInputUploadError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct DogfoodEvalUploadError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct MeshJointInferenceRequestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class JointInferenceStatusThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minTokenInterval: TimeInterval
    private var lastTokenStatusAt = Date.distantPast

    init(minTokenInterval: TimeInterval = 0.25) {
        self.minTokenInterval = minTokenInterval
    }

    func shouldForward(_ eventType: JointInferenceEventType) -> Bool {
        guard eventType == .token else { return true }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastTokenStatusAt) >= minTokenInterval else {
            return false
        }
        lastTokenStatusAt = now
        return true
    }
}

@MainActor
final class MeshManager: ObservableObject {

    static let shared = MeshManager()

    let engine = MeshEngine()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "mesh_enabled") }
    }
    @Published var jointInferenceEnabled: Bool {
        didSet { UserDefaults.standard.set(jointInferenceEnabled, forKey: Self.jointInferenceEnabledDefaultsKey) }
    }
    @Published var connectedPeerCount: Int = 0
    @Published var bestInferenceNode: MeshNode?
    @Published var lastJointInferenceStatus: String?

    @Published var trustedPeers: [TrustStore.TrustedPeer] = []

    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var activeConnections: [String: MeshConnection] = [:]
    private var jointInferenceClients: [String: JointInferenceClient] = [:]
    private lazy var haloCapsuleReceiveCoordinator = HaloCapsuleReceiveCoordinator<
        Data,
        HaloCapsuleMeshMessage,
        HaloCapsuleInboundTransferSession.CompletedPackage
    > { [unowned self] peerId in
        self.makeHaloCapsuleSession(peerId: peerId)
    }
    private lazy var haloCapsuleOfferCoordinator = makeHaloCapsuleOfferCoordinator()
    private var haloCapsuleOfferCancellable: AnyCancellable?
    private var learningStateCancellables = Set<AnyCancellable>()
    private lazy var deviceLearningSnapshotRefreshCoordinator = HaloDebouncedRefreshCoordinator { [weak self] reason in
        await self?.broadcastDeviceLearningSnapshot(reason: reason)
    }

    fileprivate var _trainingPeerId: String?

    @Published var lastTrainingSuggestionError: String?
    @Published var lastRPPArtifactUploadRunID: String?
    @Published var lastRPPArtifactUploadError: String?
    @Published var lastPersonaRPPInputUploadID: String?
    @Published var lastPersonaRPPInputUploadError: String?
    @Published var lastPersonaSourceUploadID: String?
    @Published var lastPersonaSourceUploadError: String?
    @Published var lastDogfoodEvalUploadRunID: String?
    @Published var lastDogfoodEvalUploadError: String?

    @Published var pendingTrainingSuggestion: TrainingSuggestion?
    @Published var pendingHaloCapsuleOffer: HaloCapsuleOfferPrompt?
    @Published private(set) var latestHaloCapsuleApplyStatus: HaloCapsuleApplyStatusPayload?

    struct TrainingSuggestion: Identifiable, Equatable {
        let peerId: String          // the Mac peer that sent the suggestion
        let newEventCount: Int
        let threshold: Int
        var id: String { peerId }
    }

    private struct PendingHaloCapsuleOfferContext: Sendable {
        let offer: HaloCapsuleMeshMessage
        let peerId: String
        let connection: MeshConnection
    }

    @Published private(set) var isSecurityReady: Bool = false

    @Published var lastSecurityError: String?


    static let jointInferenceEnabledDefaultsKey = "edge_mesh_joint_inference_enabled"

    var localPeerId: String {
        if let v = UserDefaults.standard.string(forKey: "mesh_local_peer_id"), !v.isEmpty {
            return v
        }
        let fresh = "ios-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: "mesh_local_peer_id")
        return fresh
    }

    var localDisplayName: String {
        if let custom = UserDefaults.standard.string(forKey: "mesh_local_display_name"), !custom.isEmpty {
            return custom
        }
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    var localFingerprint: String? {
        engine.localFingerprint
    }

    private init() {
        if UserDefaults.standard.object(forKey: "mesh_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "mesh_enabled")
        }
        self.isEnabled = UserDefaults.standard.bool(forKey: "mesh_enabled")
        self.jointInferenceEnabled = UserDefaults.standard.bool(forKey: Self.jointInferenceEnabledDefaultsKey)
        haloCapsuleOfferCancellable = haloCapsuleOfferCoordinator.$pendingOffer
            .sink { [weak self] offer in
                self?.pendingHaloCapsuleOffer = offer
            }
        installLearningStateObservers()
    }


    func setupSecurityIfNeeded() async {
        guard !isSecurityReady else { return }
        let peerId = self.localPeerId
        let displayName = self.localDisplayName

        let result: Result<(CertificateManager.Identity, TrustStore), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let identity = try CertificateManager.loadOrCreate(peerId: peerId, displayName: displayName)
                let trustStore = try TrustStore(url: TrustStore.defaultURL())
                return .success((identity, trustStore))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (identity, trustStore)):
            engine.installSecurity(identity: identity, trustStore: trustStore)
            isSecurityReady = true
            lastSecurityError = nil
            refreshTrustedPeers()
            startIfEnabled()
            startAutoReconnectForAllTrusted()
        case .failure(let error):
            lastSecurityError = String(describing: error)
            debugPrint("[MeshManager] setupSecurity failed: \(error)")
        }
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        do {
            try engine.startDiscovery()
        } catch {
            debugPrint("[MeshManager] Discovery failed: \(error)")
        }
    }

    func stop() {
        engine.stopDiscovery()
        deviceLearningSnapshotRefreshCoordinator.cancel()
        connectedPeerCount = 0
        bestInferenceNode = nil
    }

    func toggle() {
        isEnabled.toggle()
        if isEnabled {
            startIfEnabled()
        } else {
            stop()
        }
    }


    func updateBestNode(modelSizeGB: Double) {
        bestInferenceNode = engine.bestNode(for: modelSizeGB)
    }

    func routingPlan(modelSizeGB: Double) -> RoutingPlan {
        engine.routingPlan(for: modelSizeGB)
    }


    func refreshState() {
        connectedPeerCount = engine.peers.count
        refreshTrustedPeers()
    }

    func refreshTrustedPeers() {
        guard isSecurityReady else {
            trustedPeers = []
            return
        }
        do {
            trustedPeers = try engine.listTrustedPeers()
        } catch {
            debugPrint("[MeshManager] listTrustedPeers failed: \(error)")
        }
    }


    @discardableResult
    func completePairing(with payload: QRPairingPayload) async throws -> PairingService.Result {
        if !isSecurityReady {
            await setupSecurityIfNeeded()
        }
        guard isSecurityReady else {
            throw MeshError.identityUnavailable(lastSecurityError ?? "security setup failed")
        }
        let result = try await engine.completePairing(
            with: payload,
            localPeerId: localPeerId,
            localDisplayName: localDisplayName
        )
        refreshTrustedPeers()
        startAutoReconnect(peerId: result.node.id)
        return result
    }

    func exchangePinForPayload(pin: String, host: String, httpPort: UInt16) async throws -> QRPairingPayload {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            throw MeshError.pairingInvalid("empty PIN")
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, httpPort > 0 else {
            NSLog("[MeshManager] exchangePinForPayload aborted: empty host/port (host=\"\(host)\" port=\(httpPort))")
            throw MeshError.pairingInvalid("host endpoint not yet resolved, try again")
        }
        let urlString = "http://\(trimmedHost):\(httpPort)/api/mesh/pair/pin"
        guard let url = URL(string: urlString) else {
            throw MeshError.pairingInvalid("invalid host/port")
        }
        NSLog("[MeshManager] PIN exchange → \(urlString)  pin=\(trimmed.prefix(2))****")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let body = try JSONSerialization.data(withJSONObject: ["pin": trimmed], options: [])
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                NSLog("[MeshManager] PIN exchange: no HTTP response object")
                throw MeshError.pairingInvalid("no http response")
            }
            NSLog("[MeshManager] PIN exchange got HTTP \(http.statusCode) (\(data.count) bytes)")
            guard (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw MeshError.pairingInvalid("pin exchange failed http=\(http.statusCode) \(msg)")
            }
            return try QRPairingPayload.decode(jsonData: data)
        } catch {
            NSLog("[MeshManager] PIN exchange URLSession error: \(error.localizedDescription)")
            throw error
        }
    }

    func revoke(peerId: String) async throws {
        try await notifyRemotePeerTrustDeleted(peerId: peerId, reason: "user_revoked_peer")
        stopAutoReconnect(peerId: peerId)
        try engine.revoke(peerId: peerId)
        refreshTrustedPeers()
    }


    struct PairRequestResult: Decodable, Sendable {
        let pin: String
        let nonce: String
        let ttl_seconds: Int
    }

    func completeTapToPairFlow(with host: MeshNode) async throws -> Bool {
        let result = try await requestPairing(with: host)
        let deadline = Date().addingTimeInterval(TimeInterval(result.ttl_seconds))
        while Date() < deadline {
            if Task.isCancelled { return false }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let state = try? await pairStatus(nonce: result.nonce, host: host) {
                switch state {
                case "approved":
                    let httpPort = host.httpPort ?? 18842
                    let payload = try await exchangePinForPayload(
                        pin: result.pin,
                        host: host.endpoint.host,
                        httpPort: httpPort
                    )
                    _ = try await completePairing(with: payload)
                    return true
                case "expired", "unknown":
                    return false
                default:
                    continue   // still "pending" — keep waiting
                }
            }
        }
        return false
    }

    func pairStatusPublic(nonce: String, host: MeshNode) async throws -> String {
        try await pairStatus(nonce: nonce, host: host)
    }

    private func pairStatus(nonce: String, host: MeshNode) async throws -> String {
        let httpPort = host.httpPort ?? 18842
        let ipv4 = host.endpoint.host
        guard !ipv4.isEmpty, httpPort > 0 else { return "unknown" }
        guard let url = URL(string: "http://\(ipv4):\(httpPort)/api/mesh/pair/status/\(nonce)") else {
            return "unknown"
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return "unknown"
        }
        struct StatusResp: Decodable { let state: String }
        return (try? JSONDecoder().decode(StatusResp.self, from: data))?.state ?? "unknown"
    }

    func requestPairing(with host: MeshNode) async throws -> PairRequestResult {
        guard isSecurityReady else {
            throw MeshError.identityUnavailable("security not initialized")
        }
        let httpPort = host.httpPort ?? 18842
        let ipv4 = host.endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ipv4.isEmpty, httpPort > 0 else {
            throw MeshError.pairingInvalid("host endpoint not yet resolved, try again")
        }
        guard let url = URL(string: "http://\(ipv4):\(httpPort)/api/mesh/pair/request") else {
            throw MeshError.pairingInvalid("invalid host/port")
        }
        guard let fingerprint = localFingerprint else {
            throw MeshError.identityUnavailable("no local fingerprint yet")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let body: [String: Any] = [
            "peer_id": localPeerId,
            "display_name": localDisplayName,
            "fingerprint": fingerprint,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        NSLog("[MeshManager] pair/request → http://\(ipv4):\(httpPort)")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw MeshError.pairingInvalid("pair/request failed: \(msg)")
        }
        return try JSONDecoder().decode(PairRequestResult.self, from: data)
    }

    func deletePeer(peerId: String) async throws {
        if let peer = trustedPeers.first(where: { $0.peerId == peerId }), !peer.revoked {
            try await notifyRemotePeerTrustDeleted(peerId: peerId, reason: "user_deleted_peer")
        } else {
            NSLog("[MeshManager] peer_trust_deleted skipped for revoked/local-only peer \(peerId)")
        }
        stopAutoReconnect(peerId: peerId)
        try engine.deletePeer(peerId: peerId)
        refreshTrustedPeers()
    }

    private func notifyRemotePeerTrustDeleted(peerId: String, reason: String) async throws {
        let payload = PeerTrustDeletedPayload(peerID: localPeerId, reason: reason)
        let connection: MeshConnection
        let shouldCancelAfterSend: Bool

        if let activeConnection = activeConnections[peerId] {
            connection = activeConnection
            shouldCancelAfterSend = false
        } else if let node = engine.peers.first(where: { $0.id == peerId && !$0.endpoint.host.isEmpty }) {
            connection = try await engine.connect(to: node)
            shouldCancelAfterSend = true
            NSLog("[MeshManager] peer_trust_deleted opened one-shot mTLS connection to \(peerId)")
        } else {
            throw MeshError.connectionFailed(
                peer: peerId,
                reason: "no active or discovered mTLS route for peer_trust_deleted"
            )
        }

        defer {
            if shouldCancelAfterSend {
                connection.cancel()
            }
        }

        let client = PeerTrustDeleteClient(
            connection: connection,
            configuration: .init(ackTimeout: 3)
        )
        let ack = try await client.sendAndWaitForAck(payload)
        NSLog(
            "[MeshManager] peer_trust_deleted ack peer=%@ reason=%@ wasKnown=%d",
            peerId,
            reason,
            ack.wasKnown
        )
    }


    func startAutoReconnectForAllTrusted() {
        for peer in trustedPeers where !peer.revoked {
            startAutoReconnect(peerId: peer.peerId)
        }
    }

    func startAutoReconnect(peerId: String) {
        guard isSecurityReady else { return }
        if reconnectTasks[peerId] != nil { return }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self = self else { return }
            await self.reconnectLoop(peerId: peerId)
        }
        reconnectTasks[peerId] = task
    }

    func stopAutoReconnect(peerId: String) {
        reconnectTasks[peerId]?.cancel()
        reconnectTasks[peerId] = nil
        activeConnections[peerId]?.cancel()
        activeConnections[peerId] = nil
        jointInferenceClients[peerId] = nil
    }

    private func reconnectLoop(peerId: String) async {
        let backoffSchedule: [UInt64] = [1, 2, 4, 8, 16, 30]
        var backoffIdx = 0

        while !Task.isCancelled {
            let snapshot: [TrustStore.TrustedPeer] = self.trustedPeers
            guard let tp = snapshot.first(where: { $0.peerId == peerId }) else {
                NSLog("[MeshManager] reconnect[\(peerId)] peer gone from TrustStore, stopping")
                return
            }
            if tp.revoked {
                NSLog("[MeshManager] reconnect[\(peerId)] revoked locally, stopping")
                return
            }

            let discovered = engine.peers.first { $0.id == peerId }
            guard let node = discovered,
                  !node.endpoint.host.isEmpty,
                  node.endpoint.port > 0 else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            do {
                let conn = try await engine.connect(to: node)
                activeConnections[peerId] = conn
                jointInferenceClients[peerId] = JointInferenceClient(connection: conn)
                NSLog("[MeshManager] reconnect[\(peerId)] connected to \(node.endpoint.host):\(node.endpoint.port)")
                backoffIdx = 0

                conn.onFrame { [weak self] data in
                    self?.handleTrainingFrame(data, peerId: peerId, connection: conn)
                    Task { [weak self] in
                        await self?.handleHaloCapsuleFrame(data, peerId: peerId, connection: conn)
                    }
                }

                await sendDeviceLearningSnapshot(to: conn, targetPeerId: peerId)
                await uploadPersonaSourcesOnConnect(connection: conn, targetPeerId: peerId)

                await awaitConnectionDrop(conn)
                activeConnections[peerId] = nil
                jointInferenceClients[peerId] = nil
                NSLog("[MeshManager] reconnect[\(peerId)] connection dropped, will retry")
            } catch {
                NSLog("[MeshManager] reconnect[\(peerId)] connect failed: \(error.localizedDescription)")
            }

            let waitS = backoffSchedule[min(backoffIdx, backoffSchedule.count - 1)]
            backoffIdx += 1
            try? await Task.sleep(nanoseconds: waitS * 1_000_000_000)
        }
    }

    private func sendDeviceLearningSnapshot(
        to connection: MeshConnection,
        targetPeerId: String
    ) async {
        do {
            let snapshot = try await ScaffoldLearningStatusProvider(
                peerID: localPeerId,
                displayName: localDisplayName
            ).makeDeviceLearningSnapshot()
            try connection.sendDeviceStateSnapshot(snapshot)
            NSLog(
                "[MeshManager] device_state_snapshot sent to %@ schema=%@",
                targetPeerId,
                snapshot.schemaVersion
            )
        } catch {
            NSLog("[MeshManager] device_state_snapshot failed for \(targetPeerId): \(error.localizedDescription)")
        }
    }

    private func installLearningStateObservers() {
        AIManager.shared.$isModelLoaded
            .sink { [weak self] isLoaded in
                guard isLoaded else { return }
                Task { @MainActor [weak self] in
                    self?.scheduleDeviceLearningSnapshotRefresh(reason: "model_loaded")
                }
            }
            .store(in: &learningStateCancellables)

        AIManager.shared.$neuralImprintCacheStatus
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDeviceLearningSnapshotRefresh(reason: "neural_imprint_status_changed")
                }
            }
            .store(in: &learningStateCancellables)
    }

    func scheduleDeviceLearningSnapshotRefresh(reason: String) {
        deviceLearningSnapshotRefreshCoordinator.schedule(reason: reason)
    }

    private func broadcastDeviceLearningSnapshot(reason: String) async {
        guard !activeConnections.isEmpty else { return }
        NSLog(
            "[MeshManager] refreshing device_state_snapshot reason=%@ peers=%d",
            reason,
            activeConnections.count
        )
        for (peerId, connection) in activeConnections {
            await sendDeviceLearningSnapshot(to: connection, targetPeerId: peerId)
        }
    }

    private func awaitConnectionDrop(_ conn: MeshConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            conn.onStateChange { state in
                switch state {
                case .failed, .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                default: break
                }
            }
            switch conn.state {
            case .failed, .cancelled:
                if !resumed { resumed = true; cont.resume() }
            default: break
            }
        }
    }


    var hasReachableBrain: Bool {
        trustedPeers.contains { peer in
            !peer.revoked && activeConnections[peer.peerId] != nil
        }
    }

    var canUseJointInference: Bool {
        jointInferenceEnabled && hasReachableBrain
    }

    func meshJointInferenceGenerate(
        messages: [[String: String]],
        conversationID: String? = nil,
        maxTokens: Int = 512,
        temperature: Double = 0.2,
        enableThinking: Bool = false,
        useNeuralImprint: Bool = false,
        timeoutSec: TimeInterval = 180,
        onEvent: JointInferenceClient.EventHandler? = nil
    ) async throws -> String {
        guard let peer = trustedPeers.first(where: { !$0.revoked }) else {
            throw MeshJointInferenceRequestError(message: "no trusted Mac peer (pair first)")
        }
        guard let connection = activeConnections[peer.peerId] else {
            throw MeshJointInferenceRequestError(message: "Mac peer not connected")
        }

        let client: JointInferenceClient
        if let existing = jointInferenceClients[peer.peerId] {
            client = existing
        } else {
            let fresh = JointInferenceClient(connection: connection)
            jointInferenceClients[peer.peerId] = fresh
            client = fresh
        }

        let jointMessages = messages.compactMap { message -> JointInferenceMessage? in
            guard
                let role = message["role"],
                let content = message["content"],
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return JointInferenceMessage(role: role, content: content)
        }
        let payload = JointInferenceRequestPayload(
            requestID: UUID().uuidString,
            conversationID: conversationID,
            peerID: localPeerId,
            modelID: ScaffoldConfig.modelID,
            messages: jointMessages,
            maxTokens: maxTokens,
            temperature: temperature,
            enableThinking: enableThinking,
            useNeuralImprint: useNeuralImprint,
            routeReason: "scaffold_controlled_chat"
        )

        lastJointInferenceStatus = "Sending request to Mac"
        let statusThrottle = JointInferenceStatusThrottle()
        return try await client.generate(
            payload,
            timeoutSeconds: timeoutSec,
            onEvent: { [weak self] event in
                onEvent?(event)
                guard statusThrottle.shouldForward(event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.lastJointInferenceStatus = event.statusLabel
                }
            }
        )
    }


    func reconcilePeers() async {
        guard isSecurityReady else { return }
        let snapshot = engine.peers
        let peersToCheck = trustedPeers
        guard !peersToCheck.isEmpty else { return }

        for peer in peersToCheck {
            let match = snapshot.first { $0.id == peer.peerId }
            guard let host = match?.endpoint.host, !host.isEmpty else {
                NSLog("[MeshManager] reconcile skip \(peer.peerId): host not discovered")
                continue
            }
            let port = match?.httpPort ?? 18842
            guard let status = await fetchPeerStatus(host: host, port: port, peer: peer) else { continue }

            do {
                if !status.known {
                    try engine.deletePeer(peerId: peer.peerId)
                    NSLog("[MeshManager] reconcile deleted \(peer.peerId) — Mac says unknown")
                } else if status.revoked && !peer.revoked {
                    try engine.revoke(peerId: peer.peerId)
                    NSLog("[MeshManager] reconcile revoked \(peer.peerId) — Mac says revoked")
                }
            } catch {
                NSLog("[MeshManager] reconcile mutation failed for \(peer.peerId): \(error)")
            }
        }
        refreshTrustedPeers()
    }

    private struct RemotePeerStatus: Decodable {
        let known: Bool
        let trusted: Bool
        let revoked: Bool
    }

    private func fetchPeerStatus(host: String, port: UInt16, peer: TrustStore.TrustedPeer) async -> RemotePeerStatus? {
        guard let url = URL(string: "http://\(host):\(port)/api/mesh/peer_status") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        let body: [String: Any] = [
            "peer_id": localPeerId,
            "fingerprint": localFingerprint ?? ""
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(RemotePeerStatus.self, from: data)
        } catch {
            NSLog("[MeshManager] fetchPeerStatus(\(peer.peerId)) failed: \(error.localizedDescription)")
            return nil
        }
    }


    nonisolated private func handleTrainingFrame(_ data: Data, peerId: String, connection: MeshConnection?) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let op = obj["op"] as? String,
            let payload = obj["payload"] as? [String: Any]
        else { return }

        switch op {
        case "training_available":
            let newEventCount = payload["new_event_count"] as? Int ?? 0
            let threshold = payload["threshold"] as? Int ?? 0
            let senderPeerId = (payload["peer_id"] as? String) ?? peerId
            Task { @MainActor in
                self.pendingTrainingSuggestion = TrainingSuggestion(
                    peerId: senderPeerId,
                    newEventCount: newEventCount,
                    threshold: threshold
                )
                self._trainingPeerId = peerId
            }
        case "training_request_ack":
            let accepted = payload["accepted"] as? Bool ?? false
            NSLog("[MeshManager] training_request_ack accepted=\(accepted) payload=\(payload)")
        default:
            return
        }
    }

    private func handleHaloCapsuleFrame(
        _ data: Data,
        peerId: String,
        connection: MeshConnection
    ) async {
        do {
            let result = try await haloCapsuleReceiveCoordinator.receive(
                data,
                peerID: peerId
            )
            guard result.handled else { return }

            if let offer = result.acceptedOffer {
                NSLog(
                    "[MeshManager] halo_capsule_offer waiting for user peer=%@ transfer=%@ capsule=%@ bytes=%d",
                    peerId,
                    offer.transferID,
                    offer.capsule.capsuleID,
                    offer.capsule.artifact.totalBytes
                )
                presentHaloCapsuleOffer(offer, peerId: peerId, connection: connection)
            } else {
                for frame in result.outgoingFrames {
                    try await connection.sendAndWait(frame)
                }
            }
            if let rejected = result.rejectedOffer {
                NSLog(
                    "[MeshManager] halo_capsule_offer rejected peer=%@ transfer=%@ reason=%@",
                    peerId,
                    rejected.transferID,
                    rejected.reason ?? ""
                )
            }
            if let completed = result.completedPackage {
                await applyCompletedHaloCapsule(completed, peerId: peerId, connection: connection)
            }
        } catch {
            let offer = await haloCapsuleReceiveCoordinator.reset(peerID: peerId)
            NSLog("[MeshManager] halo_capsule_receive failed peer=\(peerId): \(error)")
            if let offer {
                await sendHaloCapsuleApplyStatus(
                    for: offer,
                    status: .failed,
                    connection: connection,
                    errorCode: "receive_failed",
                    errorMessage: String(describing: error)
                )
            }
        }
    }

    private func presentHaloCapsuleOffer(
        _ offer: HaloCapsuleMeshMessage,
        peerId: String,
        connection: MeshConnection
    ) {
        haloCapsuleOfferCoordinator.present(
            offer: offer,
            context: PendingHaloCapsuleOfferContext(
                offer: offer,
                peerId: peerId,
                connection: connection
            ),
            prompt: HaloCapsuleOfferPrompt(
                transferID: offer.transferID,
                sourceDisplayName: displayName(forPeerID: peerId),
                baseModelID: offer.capsule.baseModelID,
                prefixTokenCount: offer.capsule.requirements.prefixTokenCount,
                artifactSHA12: String(offer.capsule.artifact.sha256.prefix(12))
            )
        )
    }

    func acceptPendingHaloCapsuleOffer(id: String) {
        haloCapsuleOfferCoordinator.accept(id: id)
    }

    func rejectPendingHaloCapsuleOffer(id: String) {
        haloCapsuleOfferCoordinator.reject(id: id)
    }

    private func makeHaloCapsuleOfferCoordinator()
        -> HaloCapsuleOfferCoordinator<HaloCapsuleMeshMessage, PendingHaloCapsuleOfferContext>
    {
        HaloCapsuleOfferCoordinator(
            onAccept: { [weak self] pending in
                await self?.handleAcceptedHaloCapsuleOffer(pending.context)
            },
            onReject: { [weak self] pending, reason in
                await self?.handleRejectedHaloCapsuleOffer(
                    pending.context,
                    reason: reason
                )
            },
            onSupersede: { [weak self] pending, reason in
                await self?.handleSupersededHaloCapsuleOffer(
                    pending.context,
                    reason: reason
                )
            }
        )
    }

    private func handleAcceptedHaloCapsuleOffer(
        _ context: PendingHaloCapsuleOfferContext
    ) async {
        do {
            try await sendHaloCapsuleOfferAck(
                for: context.offer,
                accepted: true,
                reason: nil,
                connection: context.connection
            )
            NSLog(
                "[MeshManager] halo_capsule_offer user accepted peer=%@ transfer=%@ capsule=%@",
                context.peerId,
                context.offer.transferID,
                context.offer.capsule.capsuleID
            )
            if HaloCapsuleDownloadTransport.usesDownloadTransport(context.offer) {
                await haloCapsuleReceiveCoordinator.reset(peerID: context.peerId)
                await downloadAndApplyHaloCapsuleOffer(
                    context.offer,
                    peerId: context.peerId,
                    connection: context.connection
                )
            }
        } catch {
            await haloCapsuleReceiveCoordinator.reset(peerID: context.peerId)
            NSLog("[MeshManager] halo_capsule accept failed peer=\(context.peerId): \(error)")
            await sendHaloCapsuleApplyStatus(
                for: context.offer,
                status: .failed,
                connection: context.connection,
                errorCode: "offer_ack_failed",
                errorMessage: String(describing: error)
            )
        }
    }

    private func handleRejectedHaloCapsuleOffer(
        _ context: PendingHaloCapsuleOfferContext,
        reason: String
    ) async {
        await haloCapsuleReceiveCoordinator.reset(peerID: context.peerId)
        do {
            try await sendHaloCapsuleOfferAck(
                for: context.offer,
                accepted: false,
                reason: reason,
                connection: context.connection
            )
            NSLog(
                "[MeshManager] halo_capsule_offer user rejected peer=%@ transfer=%@ capsule=%@",
                context.peerId,
                context.offer.transferID,
                context.offer.capsule.capsuleID
            )
        } catch {
            NSLog("[MeshManager] halo_capsule reject ack failed peer=\(context.peerId): \(error)")
        }
    }

    private func handleSupersededHaloCapsuleOffer(
        _ context: PendingHaloCapsuleOfferContext,
        reason: String
    ) async {
        await haloCapsuleReceiveCoordinator.reset(peerID: context.peerId)
        do {
            try await sendHaloCapsuleOfferAck(
                for: context.offer,
                accepted: false,
                reason: reason,
                connection: context.connection
            )
        } catch {
            NSLog("[MeshManager] halo_capsule supersede ack failed peer=\(context.peerId): \(error)")
        }
    }

    private func sendHaloCapsuleOfferAck(
        for offer: HaloCapsuleMeshMessage,
        accepted: Bool,
        reason: String?,
        connection: MeshConnection
    ) async throws {
        let ack = HaloCapsuleTransferAck(
            transferID: offer.transferID,
            accepted: accepted,
            reason: reason,
            canonicalSHA256: accepted ? try offer.canonicalSHA256() : nil
        )
        let frame = try HaloCapsulePackageTransfer.makeOfferAckFrame(ack)
        try await connection.sendAndWait(frame)
    }

    private func downloadAndApplyHaloCapsuleOffer(
        _ offer: HaloCapsuleMeshMessage,
        peerId: String,
        connection: MeshConnection
    ) async {
        let destination = Self.haloCapsuleInboxDirectory(
            peerId: peerId,
            transferID: offer.transferID
        )
        do {
            let completed = try await HaloCapsuleDownloadTransport().downloadPackage(
                message: offer,
                to: destination
            )
            await applyCompletedHaloCapsule(completed, peerId: peerId, connection: connection)
        } catch {
            await sendHaloCapsuleApplyStatus(
                for: offer,
                status: .failed,
                connection: connection,
                canonicalSHA256: try? offer.canonicalSHA256(),
                errorCode: "download_failed",
                errorMessage: String(describing: error)
            )
            NSLog("[MeshManager] halo_capsule download failed peer=\(peerId): \(error)")
        }
    }

    private func makeHaloCapsuleSession(
        peerId: String
    ) -> AnyHaloCapsuleInboundSession<
        Data,
        HaloCapsuleMeshMessage,
        HaloCapsuleInboundTransferSession.CompletedPackage
    > {
        let session = HaloCapsuleInboundTransferSession { offer in
            let policy = try ScaffoldHaloCapsulePolicy.snapshot()
            return HaloCapsulePackageReceiver.Configuration(
                destinationDirectory: Self.haloCapsuleInboxDirectory(
                    peerId: peerId,
                    transferID: offer.transferID
                ),
                expectedBaseModelID: policy.baseModelID,
                expectedModelFamily: ScaffoldConfig.rppModelFamily,
                expectedHiddenSize: ScaffoldConfig.rppHiddenSize,
                expectedLayerCount: ScaffoldConfig.rppLayerCount,
                expectedToolSchemaSHA256: policy.toolSchemaSHA256,
                currentRuntimeVersion: policy.currentRuntimeVersion
            )
        }
        return AnyHaloCapsuleInboundSession(
            hasActiveTransfer: { session.hasActiveTransfer },
            activeOffer: { session.activeOffer },
            reset: { session.reset() },
            receive: { frame in
                let result = try session.receive(frame)
                return HaloCapsuleReceiveResult(
                    handled: result.handled,
                    outgoingFrames: result.outgoingFrames,
                    acceptedOffer: result.acceptedOffer,
                    rejectedOffer: result.rejectedOfferAck.map {
                        HaloCapsuleRejectedOffer(
                            transferID: $0.transferID,
                            reason: $0.reason
                        )
                    },
                    completedPackage: result.completedPackage
                )
            }
        )
    }

    private func applyCompletedHaloCapsule(
        _ completed: HaloCapsuleInboundTransferSession.CompletedPackage,
        peerId: String,
        connection: MeshConnection
    ) async {
        let message = completed.message
        let recordApplyStatus: @Sendable (HaloCapsuleApplyStatusPayload) async -> Void = { [weak self] payload in
            await self?.rememberHaloCapsuleApplyStatus(payload)
        }
        let coordinator = HaloCapsuleAutoRestoreCoordinator(
            restorePackage: { completed in
                let status = try await AIManager.shared.installAndRestoreNeuralImprintCacheFromHaloPackage(
                    at: completed.packageDirectory
                )
                return HaloCapsuleAutoRestoreCoordinator.RestoreResult(
                    prefixTokenCount: status.prefixTokenCount
                )
            },
            sendApplyStatus: { payload in
                await recordApplyStatus(payload)
                try await Self.sendHaloCapsuleApplyStatusPayload(payload, connection: connection)
            }
        )
        do {
            let result = try await coordinator.apply(completed)
            switch result.outcome {
            case .applied(let restoreResult):
                NSLog(
                    "[MeshManager] halo_capsule applied peer=%@ transfer=%@ capsule=%@ prefix=%d",
                    peerId,
                    message.transferID,
                    message.capsule.capsuleID,
                    restoreResult.prefixTokenCount ?? 0
                )
                await sendDeviceLearningSnapshot(to: connection, targetPeerId: peerId)
            case .failed(_, let errorMessage):
                NSLog(
                    "[MeshManager] halo_capsule restore failed peer=%@ transfer=%@ capsule=%@: %@",
                    peerId,
                    message.transferID,
                    message.capsule.capsuleID,
                    errorMessage
                )
            }
        } catch {
            NSLog("[MeshManager] halo_capsule apply-status send failed peer=\(peerId): \(error)")
        }
    }

    private func sendHaloCapsuleApplyStatus(
        for message: HaloCapsuleMeshMessage,
        status: HaloCapsuleApplyStatusValue,
        connection: MeshConnection,
        canonicalSHA256: String? = nil,
        prefixTokenCount: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async {
        let payload = HaloCapsuleApplyStatusPayload(
            transferID: message.transferID,
            capsuleID: message.capsule.capsuleID,
            status: status,
            artifactSHA256: message.capsule.artifact.sha256,
            canonicalSHA256: canonicalSHA256,
            runtimeVersion: EdgeKitRuntime.version,
            prefixTokenCount: prefixTokenCount,
            appliedAtUnixSeconds: Date().timeIntervalSince1970,
            errorCode: errorCode,
            errorMessage: errorMessage.map { String($0.prefix(500)) }
        )
        rememberHaloCapsuleApplyStatus(payload)
        do {
            try await Self.sendHaloCapsuleApplyStatusPayload(payload, connection: connection)
        } catch {
            NSLog("[MeshManager] halo_capsule_apply_status send failed: \(error)")
        }
    }

    private func rememberHaloCapsuleApplyStatus(_ payload: HaloCapsuleApplyStatusPayload) {
        latestHaloCapsuleApplyStatus = payload
    }

    private nonisolated static func sendHaloCapsuleApplyStatusPayload(
        _ payload: HaloCapsuleApplyStatusPayload,
        connection: MeshConnection
    ) async throws {
        let frame = try HaloCapsulePackageTransfer.makeApplyStatusFrame(payload)
        try await connection.sendAndWait(frame)
        NSLog(
            "[MeshManager] halo_capsule_apply_status sent transfer=%@ capsule=%@ status=%@",
            payload.transferID,
            payload.capsuleID,
            payload.status.rawValue
        )
    }

    private static func haloCapsuleInboxDirectory(peerId: String, transferID: String) -> URL {
        documentsDirectory
            .appendingPathComponent("halo_capsule", isDirectory: true)
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent(
                "\(safePathComponent(peerId))-\(safePathComponent(transferID))",
                isDirectory: true
            )
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let normalized = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return normalized.isEmpty ? "unknown" : normalized
    }

    private func displayName(forPeerID peerId: String) -> String {
        trustedPeers.first(where: { $0.peerId == peerId })?.displayName ?? peerId
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    func acceptTrainingSuggestion() {
        guard let suggestion = pendingTrainingSuggestion else { return }
        guard let peerId = _trainingPeerId, let conn = activeConnections[peerId] else {
            lastTrainingSuggestionError = "Mac 连接已断开，稍后重试"
            return
        }
        do {
            let envelope: [String: Any] = ["op": "training_request", "payload": [:]]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            try conn.send(data)
            NSLog("[MeshManager] training_request sent to \(peerId)")
            pendingTrainingSuggestion = nil
            lastTrainingSuggestionError = nil
            _ = suggestion
        } catch {
            lastTrainingSuggestionError = "发送训练请求失败: \(error.localizedDescription)"
        }
    }

    func dismissTrainingSuggestion() {
        pendingTrainingSuggestion = nil
    }


    @discardableResult
    func uploadLatestRPPArtifactsToMac() async throws -> String {
        let upload = try Self.buildLatestRPPArtifactUploadPayload(
            localPeerId: localPeerId
        )
        guard let runID = upload["rpp_run_id"] as? String,
              !runID.isEmpty else {
            throw RPPArtifactUploadError(message: "rpp_last_run.json missing rpp_run_id")
        }
        guard let connection = activeConnections.values.first else {
            throw RPPArtifactUploadError(message: "No active paired Mac connection")
        }

        let frame: [String: Any] = [
            "op": "rpp_artifact_upload",
            "payload": upload,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        try connection.send(data)
        lastRPPArtifactUploadRunID = runID
        lastRPPArtifactUploadError = nil
        NSLog("[MeshManager] rpp_artifact_upload sent run_id=\(runID)")

        do {
            let sourceResult = try await uploadPersonaSourceToMac(
                kind: .deviceRPPProfile,
                connection: connection,
                targetPeerId: nil
            )
            recordPersonaSourceUpload(result: sourceResult, kind: .deviceRPPProfile)
        } catch {
            lastPersonaSourceUploadError = error.localizedDescription
            NSLog("[MeshManager] device_rpp_profile persona_source_upload failed after legacy upload: \(error)")
        }
        return runID
    }

    private func uploadPersonaSourcesOnConnect(
        connection: MeshConnection,
        targetPeerId: String
    ) async {
        do {
            let result = try await uploadPersonaSourceToMac(
                kind: .toolSchemaOnly,
                connection: connection,
                targetPeerId: targetPeerId
            )
            recordPersonaSourceUpload(result: result, kind: .toolSchemaOnly)
        } catch {
            lastPersonaSourceUploadError = error.localizedDescription
            NSLog("[MeshManager] tool_schema_only persona_source_upload failed: \(error)")
        }

        guard Self.latestRPPProfileSource() != nil else { return }
        do {
            let result = try await uploadPersonaSourceToMac(
                kind: .deviceRPPProfile,
                connection: connection,
                targetPeerId: targetPeerId
            )
            recordPersonaSourceUpload(result: result, kind: .deviceRPPProfile)
        } catch {
            lastPersonaSourceUploadError = error.localizedDescription
            NSLog("[MeshManager] device_rpp_profile persona_source_upload failed: \(error)")
        }
    }

    private func uploadPersonaSourceToMac(
        kind: HaloPersonaSourceKind,
        connection: MeshConnection,
        targetPeerId: String?
    ) async throws -> PersonaSourceUploadResult {
        let peerId = targetPeerId ?? activeConnections.first { $0.value === connection }?.key
            ?? "unknown-peer"
        let coordinator = PersonaSourceUploadCoordinator(
            provider: ScaffoldPersonaSourceProvider(kind: kind),
            uploader: PersonaSourceMeshUploader(
                peerID: localPeerId,
                connection: connection
            ),
            stateStore: PersonaSourceUserDefaultsStateStore(
                key: Self.personaSourceUploadStateKey(kind: kind, peerId: peerId)
            )
        )
        return try await coordinator.uploadIfNeeded(kind: kind)
    }

    private func recordPersonaSourceUpload(
        result: PersonaSourceUploadResult,
        kind: HaloPersonaSourceKind
    ) {
        switch result.decision {
        case .upload:
            if let receipt = result.receipt {
                lastPersonaSourceUploadID = receipt.sourceID
                lastPersonaSourceUploadError = nil
                NSLog(
                    "[MeshManager] persona_source_upload stored kind=%@ source_id=%@",
                    kind.rawValue,
                    receipt.sourceID
                )
            }
        case let .skip(reason, fingerprint):
            lastPersonaSourceUploadError = nil
            NSLog(
                "[MeshManager] persona_source_upload skipped kind=%@ reason=%@ fingerprint=%@",
                kind.rawValue,
                reason,
                String(fingerprint.prefix(12))
            )
        }
    }

    private static func personaSourceUploadStateKey(
        kind: HaloPersonaSourceKind,
        peerId: String
    ) -> String {
        [
            "persona_source_upload",
            "last_fingerprint",
            ScaffoldConfig.modelID,
            peerId,
            kind.rawValue,
        ].joined(separator: ".")
    }

    @discardableResult
    func uploadPersonaRPPInputToMac(limit: Int = 10_000) async throws -> String {
        guard let mac = trustedPeers.first(where: { !$0.revoked }) else {
            throw PersonaRPPInputUploadError(message: "no trusted Mac peer")
        }
        guard let connection = activeConnections[mac.peerId] else {
            throw PersonaRPPInputUploadError(message: "Mac peer not connected")
        }

        let payload = try ScaffoldPersonaRPPInputExporter.payload(
            peerID: localPeerId,
            appID: Bundle.main.bundleIdentifier ?? "com.atomgradient.edgescaffolding",
            baseModelID: ScaffoldConfig.modelID,
            sourceKind: .appFacts,
            sourceRecords: ScaffoldPersonaRPPInputExporter.demoSourceRecords(limit: limit),
            inputNote: "edge-scaffold canonical exporter sample"
        )
        let client = PersonaRPPInputUploadClient(
            connection: connection,
            configuration: .init(ackTimeout: 8)
        )
        let ack = try await client.sendAndWaitForAck(payload)
        guard ack.ok else {
            throw PersonaRPPInputUploadError(message: ack.message ?? "persona_rpp_input_upload failed")
        }
        guard let inputID = ack.inputID, !inputID.isEmpty else {
            throw PersonaRPPInputUploadError(message: "Malformed persona_rpp_input_upload_ack")
        }

        lastPersonaRPPInputUploadID = inputID
        lastPersonaRPPInputUploadError = nil
        NSLog(
            "[MeshManager] persona_rpp_input_upload stored input_id=%@ records=%d",
            inputID,
            ack.recordCount ?? payload.records.count
        )
        return inputID
    }

    fileprivate static func buildPersonaSourceMaterial(
        kind: HaloPersonaSourceKind
    ) throws -> PersonaSourceMaterial {
        let snapshot = try AIManager.neuralImprintToolSchemaSnapshot()
        let profileSource = kind == .toolSchemaOnly ? nil : latestRPPProfileSource()
        return PersonaSourceMaterial(
            appID: Bundle.main.bundleIdentifier ?? "com.atomgradient.edgescaffolding",
            baseModelID: ScaffoldConfig.modelID,
            toolSchemaJSON: snapshot.jsonString ?? String(decoding: snapshot.jsonData, as: UTF8.self),
            toolSchemaSHA256: snapshot.sha256,
            profileBody: profileSource?.body,
            rppRunID: profileSource?.rppRunID
        )
    }

    private struct RPPProfileSource {
        let rppRunID: String
        let body: String
    }

    private static func latestRPPProfileSource() -> RPPProfileSource? {
        guard
            let docs = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else { return nil }
        let url = docs.appendingPathComponent("rpp_last_run.json")
        guard
            let data = try? Data(contentsOf: url),
            let rppLastRun = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let runID = rppLastRun["rpp_run_id"] as? String,
            !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let body = renderPersonaSourceProfileBody(from: rppLastRun)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return RPPProfileSource(rppRunID: runID, body: body)
    }

    private static func renderPersonaSourceProfileBody(
        from rppLastRun: [String: Any]
    ) -> String {
        var sections: [String] = []
        let runID = rppLastRun["rpp_run_id"] as? String ?? "unknown"
        let n = rppLastRun["n_transactions"] as? Int ?? 0
        let layer = rppLastRun["target_layer"] as? Int ?? ScaffoldConfig.rppTargetLayer
        let kSelected = rppLastRun["k_selected"] as? Int ?? 0
        sections.append(
            "RPP run \(runID)\n数据范围：\(n) 条已分类本机记录，target_layer=\(layer)，k_selected=\(kSelected)"
        )

        if let summary = rppLastRun["dataset_summary"] as? [String: Any] {
            let total = summary["total_amount"] as? Double ?? 0
            let average = summary["average_amount"] as? Double ?? 0
            let median = summary["median_amount"] as? Double ?? 0
            let max = summary["max_amount"] as? Double ?? 0
            sections.append(
                "金额摘要：total=\(formatPersonaSourceAmount(total))，average=\(formatPersonaSourceAmount(average))，median=\(formatPersonaSourceAmount(median))，max=\(formatPersonaSourceAmount(max))"
            )
            appendBucketSection(
                title: "按次数最高的类别",
                key: "top_categories_by_count",
                summary: summary,
                sections: &sections
            )
            appendBucketSection(
                title: "按金额最高的类别",
                key: "top_categories_by_amount",
                summary: summary,
                sections: &sections
            )
            appendBucketSection(
                title: "按次数最高的星期",
                key: "top_weekdays_by_count",
                summary: summary,
                sections: &sections
            )
        }

        if let narrative = rppLastRun["profile_narrative"] as? String,
           !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("综合画像：\n\(narrative)")
        }

        if let directions = rppLastRun["directions"] as? [[String: Any]] {
            let lines = directions.compactMap { direction -> String? in
                let key = direction["direction_key"] as? String ?? ""
                let name = direction["llm_name"] as? String ?? key
                let reason = direction["llm_reason"] as? String ?? ""
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty || !detail.isEmpty else { return nil }
                if detail.isEmpty { return "- \(title)" }
                if title.isEmpty { return "- \(detail)" }
                return "- \(title)：\(detail)"
            }
            if !lines.isEmpty {
                sections.append("RPP 画像方向：\n" + lines.joined(separator: "\n"))
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private static func appendBucketSection(
        title: String,
        key: String,
        summary: [String: Any],
        sections: inout [String]
    ) {
        guard let buckets = summary[key] as? [[String: Any]], !buckets.isEmpty else {
            return
        }
        let entries = buckets.prefix(8).compactMap { bucket -> String? in
            guard let label = bucket["key"] as? String, !label.isEmpty else {
                return nil
            }
            let count = bucket["count"] as? Int ?? 0
            let total = bucket["total_amount"] as? Double ?? 0
            let average = bucket["average_amount"] as? Double ?? 0
            return "\(label)(count=\(count), total=\(formatPersonaSourceAmount(total)), avg=\(formatPersonaSourceAmount(average)))"
        }
        if !entries.isEmpty {
            sections.append("\(title)：\(entries.joined(separator: "; "))")
        }
    }

    private static func formatPersonaSourceAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func buildLatestRPPArtifactUploadPayload(
        localPeerId: String
    ) throws -> [String: Any] {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw RPPArtifactUploadError(message: "Documents directory unavailable")
        }
        let url = docs.appendingPathComponent("rpp_last_run.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RPPArtifactUploadError(message: "rpp_last_run.json not found")
        }
        let data = try Data(contentsOf: url)
        guard let rppLastRun = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPPArtifactUploadError(message: "rpp_last_run.json is not an object")
        }
        guard let runID = rppLastRun["rpp_run_id"] as? String,
              !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPPArtifactUploadError(message: "rpp_last_run.json missing rpp_run_id")
        }

        let layerID = rppLastRun["target_layer"] as? Int ?? 23
        var payload: [String: Any] = [
            "schema_version": "edgestudio.rpp_artifact_upload.v0",
            "peer_id": localPeerId,
            "rpp_run_id": runID,
            "base_model_id": ScaffoldConfig.modelID,
            "layer_id": layerID,
            "rpp_last_run": rppLastRun,
        ]
        if let aHash = rppLastRun["a_hash"] as? String,
           !aHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["a_hash"] = aHash
        }
        if let aVersion = rppLastRun["a_version"] as? String,
           !aVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["a_version"] = aVersion
        }
        if let summary = rppLastRun["dataset_summary"] as? [String: Any] {
            payload["dataset_summary"] = summary
        } else {
            payload["dataset_summary"] = [
                "n_transactions": rppLastRun["n_transactions"] as? Int ?? 0,
                "k_selected": rppLastRun["k_selected"] as? Int ?? 0,
            ]
        }
        let bURL = docs.appendingPathComponent(
            "B_directions_layer_\(layerID).safetensors"
        )
        if FileManager.default.fileExists(atPath: bURL.path) {
            let bData = try Data(contentsOf: bURL)
            payload["artifacts"] = [[
                "name": bURL.lastPathComponent,
                "role": "rpp_b_directions",
                "size_bytes": bData.count,
                "sha256": Self.sha256Hex(bData),
                "content_base64": bData.base64EncodedString(),
            ]]
        }
        return payload
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }


    @discardableResult
    func uploadDogfoodEvalToMac(
        runID: String,
        subject: [String: Any] = [:],
        cases: [[String: Any]],
        observations: [[String: Any]]
    ) async throws -> String {
        let normalizedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRunID.isEmpty else {
            throw DogfoodEvalUploadError(message: "dogfood eval run_id is required")
        }
        guard let connection = activeConnections.values.first else {
            throw DogfoodEvalUploadError(message: "No active paired Mac connection")
        }

        var normalizedSubject = subject
        normalizedSubject["peer_id"] = localPeerId
        let payload: [String: Any] = [
            "schema_version": "edgestudio.personal_dogfood_eval_request.v0",
            "run_id": normalizedRunID,
            "subject": normalizedSubject,
            "cases": cases,
            "observations": observations,
        ]
        let frame: [String: Any] = [
            "op": "dogfood_eval_upload",
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        try connection.send(data)
        lastDogfoodEvalUploadRunID = normalizedRunID
        lastDogfoodEvalUploadError = nil
        NSLog("[MeshManager] dogfood_eval_upload sent run_id=\(normalizedRunID) cases=\(cases.count) observations=\(observations.count)")
        return normalizedRunID
    }

}

private struct ScaffoldPersonaSourceProvider: PersonaSourceProviding {
    let kind: HaloPersonaSourceKind

    func personaSourceMaterial() async throws -> PersonaSourceMaterial {
        try await MainActor.run {
            try MeshManager.buildPersonaSourceMaterial(kind: kind)
        }
    }
}

private actor PersonaSourceUserDefaultsStateStore: PersonaSourceUploadStateStoring {
    private let key: String

    init(key: String) {
        self.key = key
    }

    func lastUploadedPersonaSourceFingerprint() async -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    func saveUploadedPersonaSourceFingerprint(_ fingerprint: String) async throws {
        UserDefaults.standard.set(fingerprint, forKey: key)
    }
}

private final class PersonaSourceMeshUploader: PersonaSourceUploading,
    @unchecked Sendable
{
    private let peerID: String
    private let connection: MeshConnection
    private let ackTimeoutSeconds: TimeInterval

    init(
        peerID: String,
        connection: MeshConnection,
        ackTimeoutSeconds: TimeInterval = 8
    ) {
        self.peerID = peerID
        self.connection = connection
        self.ackTimeoutSeconds = ackTimeoutSeconds
    }

    func uploadPersonaSource(
        _ request: PersonaSourceUploadRequest
    ) async throws -> PersonaSourceUploadReceipt {
        let exportData = Data(request.toolSchemaJSON.utf8)
        let export: ToolSchemaExport
        do {
            export = try JSONDecoder().decode(ToolSchemaExport.self, from: exportData)
        } catch {
            throw PersonaSourceMeshUploadError.invalidToolSchemaJSON(
                error.localizedDescription
            )
        }

        let payload = PersonaSourceUploadPayload(
            peerID: peerID,
            appID: request.appID,
            baseModelID: request.baseModelID,
            toolSchemaExport: export,
            toolSchemaSHA256: request.toolSchemaSHA256,
            profileBody: request.profileBody,
            profileBodySHA256: request.profileBodySHA256,
            rppRunID: request.rppRunID,
            sourceKind: edgeKitSourceKind(request.sourceKind),
            createdAt: request.createdAtUnixSeconds
        )

        let client = PersonaSourceUploadClient(
            connection: connection,
            configuration: .init(ackTimeout: ackTimeoutSeconds)
        )
        let ack = try await client.sendAndWaitForAck(payload)
        guard ack.ok else {
            throw PersonaSourceMeshUploadError.backend(
                ack.message ?? "persona_source_upload failed"
            )
        }
        guard
            let sourceID = ack.sourceID,
            let sourceSHA256 = ack.sourceSHA256
        else {
            throw PersonaSourceMeshUploadError.malformedAck
        }
        return PersonaSourceUploadReceipt(
            sourceID: sourceID,
            sourceSHA256: sourceSHA256,
            message: ack.message
        )
    }

    private func edgeKitSourceKind(
        _ kind: HaloPersonaSourceKind
    ) -> PersonaSourceKind {
        switch kind {
        case .toolSchemaOnly:
            return .toolSchemaOnly
        case .deviceRPPProfile:
            return .deviceRPPProfile
        case .hostRPPProfile:
            return .hostRPPProfile
        }
    }

}

private enum PersonaSourceMeshUploadError: LocalizedError {
    case invalidToolSchemaJSON(String)
    case backend(String)
    case malformedAck

    var errorDescription: String? {
        switch self {
        case let .invalidToolSchemaJSON(message):
            return "Invalid tool schema JSON: \(message)"
        case let .backend(message):
            return message
        case .malformedAck:
            return "Malformed persona_source_upload_ack"
        }
    }
}
