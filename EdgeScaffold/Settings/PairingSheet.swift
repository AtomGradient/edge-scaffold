// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeMesh
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

struct PairingSheet: View {

    @EnvironmentObject private var meshManager: MeshManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMethod: Method = .qr
    @State private var phase: Phase = .idle
    @State private var errorMessage: String?
    @State private var pairedDisplayName: String?

    enum Method: String, CaseIterable, Identifiable {
        case qr = "QR Code"
        case pin = "PIN Code"
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case pairing        // 正在执行 mTLS 握手
        case done(String)   // 成功，参数是 peer display name
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch phase {
                case .idle, .scanning:
                    methodPicker
                    content
                case .pairing:
                    ProgressView("Pairing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done(let name):
                    successView(peerName: name)
                case .failed(let msg):
                    failureView(message: msg)
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if case .idle = phase, selectedMethod == .qr {
                    phase = .scanning
                }
            }
        }
    }


    private var methodPicker: some View {
        Picker("Method", selection: $selectedMethod) {
            ForEach(Method.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding()
        .onChange(of: selectedMethod) { _, new in
            phase = (new == .qr) ? .scanning : .idle
        }
    }


    @ViewBuilder
    private var content: some View {
        switch selectedMethod {
        case .qr:
            qrScannerSection
        case .pin:
            pinEntrySection
        }
    }


    @ViewBuilder
    private var qrScannerSection: some View {
        #if canImport(AVFoundation) && canImport(UIKit) && !targetEnvironment(simulator)
        QRScannerView { result in
            handleScannedString(result)
        } onError: { msg in
            phase = .failed(msg)
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            Text("Scan the QR code displayed in Edge Studio → Devices.")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 32)
        }
        #else
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("QR scanning is only available on a real iOS device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
            Button("Use PIN Instead") { selectedMethod = .pin }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }


    @State private var pin: String = ""
    @State private var selectedHostPeer: MeshNode?

    @ViewBuilder
    private var pinEntrySection: some View {
        let untrusted = untrustedPeers()
        Form {
            Section {
                if untrusted.isEmpty {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text("Searching for nearby hosts…")
                            .foregroundStyle(.secondary)
                    }
                    .onAppear { ensureDiscoveryRunning() }
                } else {
                    Picker("Host", selection: $selectedHostPeer) {
                        Text("Select…").tag(MeshNode?.none)
                        ForEach(untrusted, id: \.id) { peer in
                            Text(peer.displayName).tag(Optional(peer))
                        }
                    }
                }
            } header: {
                Text("Edge Studio Host")
            } footer: {
                Text("Pick the Mac that is showing the PIN code. Only devices discovered on this network are listed.")
            }

            Section("PIN") {
                TextField("6-character code", text: $pin)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .font(.system(.title3, design: .monospaced))
            }

            Section {
                Button {
                    Task { await submitPin() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Pair")
                            .bold()
                        Spacer()
                    }
                }
                .disabled(!canSubmitPin)
            }

            if let err = errorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var canSubmitPin: Bool {
        selectedHostPeer != nil && pin.trimmingCharacters(in: .whitespaces).count >= 4
    }

    private func untrustedPeers() -> [MeshNode] {
        meshManager.engine.peers.filter { $0.trustStatus != .trusted }
    }

    private func ensureDiscoveryRunning() {
        if !meshManager.engine.isDiscovering {
            meshManager.startIfEnabled()
        }
    }


    @ViewBuilder
    private func successView(peerName: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Paired with \(peerName)")
                .font(.title3)
                .fontWeight(.semibold)
            Text("This device is now trusted and future connections will be encrypted with mTLS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func failureView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Pairing Failed")
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button("Try Again") {
                    errorMessage = nil
                    phase = selectedMethod == .qr ? .scanning : .idle
                }
                .buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }


    private func handleScannedString(_ raw: String) {
        guard case .scanning = phase else { return }
        do {
            let payload = try QRPairingPayload.decode(jsonString: raw)
            runPairing(payload)
        } catch {
            phase = .failed("Invalid QR payload: \(error.localizedDescription)")
        }
    }

    private func submitPin() async {
        guard let host = selectedHostPeer else { return }
        errorMessage = nil
        phase = .pairing
        let ipv4 = host.endpoint.host      // Bonjour 已优先填 ipv4（memory: feedback_bonjour_txt_hostname）
        let httpPort: UInt16 = host.httpPort ?? 18842
        NSLog("[PairingSheet] submitPin → node=\(host.displayName) host=\"\(ipv4)\" httpPort=\(httpPort) (TXT port=\(host.httpPort.map(String.init) ?? "nil"))")
        do {
            let payload = try await meshManager.exchangePinForPayload(
                pin: pin,
                host: ipv4,
                httpPort: httpPort
            )
            runPairing(payload)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runPairing(_ payload: QRPairingPayload) {
        phase = .pairing
        Task {
            do {
                let result = try await meshManager.completePairing(with: payload)
                await MainActor.run {
                    pairedDisplayName = result.node.displayName
                    phase = .done(result.node.displayName)
                }
            } catch {
                await MainActor.run {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}


#if canImport(AVFoundation) && canImport(UIKit) && !targetEnvironment(simulator)

struct QRScannerView: UIViewControllerRepresentable {

    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasScanned else { return }
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let value = obj.stringValue else { return }
            hasScanned = true
            DispatchQueue.main.async { [weak self] in
                self?.onScan(value)
            }
        }
    }
}

final class QRScannerViewController: UIViewController {

    weak var coordinator: QRScannerView.Coordinator?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            coordinator?.onError("No camera available on this device.")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            coordinator?.onError("Cannot open camera: \(error.localizedDescription)")
            return
        }
        guard session.canAddInput(input) else {
            coordinator?.onError("Camera input rejected.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.onError("Metadata output rejected.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }
}

#endif
