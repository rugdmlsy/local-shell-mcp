@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

struct ScannedCode: Codable, Equatable {
    let value: String
    let type: String
    let scannedAt: Date
}

@MainActor
final class CodeScannerCoordinator: ObservableObject {
    static let shared = CodeScannerCoordinator()
    private static let key = "mobile.code_scanner.last.v1"

    @Published var presenting = false
    @Published private(set) var lastScan: ScannedCode?
    @Published private(set) var message = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            lastScan = try? JSONDecoder().decode(ScannedCode.self, from: data)
        }
    }

    func startLocalScan() {
        guard UIApplication.shared.applicationState == .active else {
            message = "Code scanning requires LSM Worker to be in the foreground."
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            message = "Grant Camera permission in LSM Worker before scanning a code."
            return
        }
        message = ""
        presenting = true
    }

    func record(value: String, type: AVMetadataObject.ObjectType) {
        let scan = ScannedCode(value: value, type: type.rawValue, scannedAt: Date())
        lastScan = scan
        if let data = try? JSONEncoder().encode(scan) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        presenting = false
    }

    func cancel() { presenting = false }

    func lastInfo() -> [String: Any] {
        guard let scan = lastScan else { return ["available": false] }
        return [
            "available": true,
            "value": scan.value,
            "type": scan.type,
            "scanned_at": ISO8601DateFormatter().string(from: scan.scannedAt),
        ]
    }
}

struct CodeScannerSheet: UIViewControllerRepresentable {
    let onScan: (String, AVMetadataObject.ObjectType) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String, AVMetadataObject.ObjectType) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.tintColor = .white
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        cancel.layer.cornerRadius = 10
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancel.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let desired: [AVMetadataObject.ObjectType] = [
            .qr, .aztec, .dataMatrix, .pdf417,
            .ean8, .ean13, .upce, .code39, .code93, .code128,
        ]
        output.metadataObjectTypes = desired.filter { output.availableMetadataObjectTypes.contains($0) }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let readable = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = readable.stringValue else { return }
        delivered = true
        session.stopRunning()
        onScan?(value, readable.type)
    }

    @objc private func cancelTapped() {
        session.stopRunning()
        onCancel?()
    }
}
