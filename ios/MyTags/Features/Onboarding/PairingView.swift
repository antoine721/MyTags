import SwiftUI
import VisionKit

/// One-screen connection (decisions 0002 and 0003): scan the QR code shown by `djtag pair`,
/// or paste its text. A demo with generated data lets you try the Tag screen first.
struct PairingView: View {
    @Environment(AppModel.self) private var app
    @State private var pasted = ""
    @State private var error: String?
    @State private var working = false
    @State private var scanning = DataScannerViewController.isSupported

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            Image(systemName: "tag")
                .font(.system(size: 44, weight: .semibold))
            Text("MyTags")
                .font(.largeTitle.weight(.bold))
            if scanning {
                QRScannerView { text in connect(text) }
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary))
                    .accessibilityLabel("Scanner le QR code de « djtag pair »")
            }
            HStack {
                TextField("mytags://pair?…", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .submitLabel(.go)
                    .onSubmit { connect(pasted) }
                Button("Coller") {
                    if let text = UIPasteboard.general.string { connect(text) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemFill)))
            if working { ProgressView() }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            Button("Essayer avec des données de démonstration") {
                Task { await app.startDemo() }
            }
            .font(.footnote)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }

    private func connect(_ text: String) {
        guard !working else { return }
        guard let credentials = Credentials(pairingText: text) else {
            error = "Code non reconnu : lancer « djtag pair » sur le Mac."
            return
        }
        working = true
        error = nil
        Task {
            do {
                try await app.pair(with: credentials)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

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
