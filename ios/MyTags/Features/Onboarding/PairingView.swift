import AVFoundation
import SwiftUI
import VisionKit

/// One-screen connection (decisions 0002 and 0003): scan the QR code shown by `djtag pair`,
/// or paste its text. A demo with generated data lets you try the Tag screen first.
struct PairingView: View {
    @Environment(AppModel.self) private var app
    @State private var pasted = ""
    @State private var error: String?
    @State private var working = false
    @State private var camera: Camera = .checking
    /// Bumped after a failed pairing: a fresh scanner can read a code again.
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL

    private enum Camera { case checking, ready, denied, unavailable }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            Text("MyTags")
                .font(.title2.weight(.bold))
            switch camera {
            case .ready:
                QRScannerView { text in connect(text, scanned: true) }
                    .id(attempt)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary))
                    .accessibilityLabel("Scanner le QR code de « djtag pair »")
            case .denied:
                Button("Autoriser la caméra") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .checking, .unavailable:
                EmptyView()
            }
            HStack {
                TextField("mytags://pair?…", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .submitLabel(.go)
                    .onSubmit { connect(pasted, scanned: false) }
                Button("Coller") {
                    if let text = UIPasteboard.general.string { connect(text, scanned: false) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemFill)))
            if working { ProgressView() }
            if let message = error ?? app.pairingError {
                Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Button("Essayer avec des données de démonstration") {
                Task { await app.startDemo() }
            }
            .font(.footnote)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .task { await prepareCamera() }
    }

    /// Asks for the camera first: a scanner started without access stays black.
    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            camera = .unavailable
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if DataScannerViewController.isAvailable {
            camera = .ready
        } else {
            camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? .unavailable : .denied
        }
    }

    private func connect(_ text: String, scanned: Bool) {
        guard !working else { return }
        guard let credentials = Credentials(pairingText: text) else {
            error = "Code non reconnu : lancer « djtag pair » sur le Mac."
            if scanned { attempt += 1 }
            return
        }
        working = true
        error = nil
        Task {
            do {
                try await app.pair(with: credentials)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if scanned { attempt += 1 }
            }
            working = false
        }
    }
}

/// VisionKit live QR scanner.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .fast, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    /// Starts once the controller exists; refused before it is on screen, it is tried again just after.
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning, (try? controller.startScanning()) == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if !controller.isScanning { try? controller.startScanning() }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(code) = item, let text = code.payloadStringValue, text.hasPrefix("mytags://") {
                    delivered = true
                    onCode(text)
                    return
                }
            }
        }
    }
}
