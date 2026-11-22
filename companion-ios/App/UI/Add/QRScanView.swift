import AVFoundation
import SwiftUI
import UIKit

/// Scans the sign-in code Unified Slicer shows on the computer.
struct QRScanView: View {
    let onCode: (String) -> Void
    @State var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State var active = false
    @State var handled = false

    var body: some View {
        Group {
            switch access {
            case .authorized:
                ZStack(alignment: .bottom) {
                    ScannerPreview(active: active) { code in
                        guard !handled else { return }
                        handled = true
                        onCode(code)
                    }
                    .ignoresSafeArea()
                    Text("Scan the code on your computer (Accounts > Sign in on phone)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.7)))
                        .padding(24)
                }
            case .notDetermined:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                FormScreen("Scan code") {
                    Hint("The camera is needed to scan the code. Allow it for Unified Monitor in Settings.")
                    PrimaryButton(title: "Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .studioBackground()
        .navigationTitle("Scan code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            handled = false
            active = true
        }
        .onDisappear { active = false }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

private struct ScannerPreview: UIViewRepresentable {
    let active: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> QRDelegate { QRDelegate() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.configure(delegate: context.coordinator)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        let handler = onCode
        context.coordinator.onCode = { code in Task { @MainActor in handler(code) } }
        view.setRunning(active)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: QRDelegate) {
        view.setRunning(false)
    }
}

final class QRDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if let text = code.stringValue, !text.isEmpty {
                onCode?(text)
                return
            }
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.unifiedslicer.monitor.scanner")

    func configure(delegate: QRDelegate) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.session = session
            preview.videoGravity = .resizeAspectFill
        }
    }

    func setRunning(_ on: Bool) {
        let session = self.session
        queue.async {
            if on, !session.isRunning {
                session.startRunning()
            } else if !on, session.isRunning {
                session.stopRunning()
            }
        }
    }
}
