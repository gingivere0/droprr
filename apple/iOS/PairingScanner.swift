import SwiftUI
import VisionKit

/// Full-screen camera that looks for a Droprr pairing QR code.
struct PairingScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { code in
                        guard code.lowercased().hasPrefix("droprr://pair") else { return }
                        dismiss()
                        onCode(code)
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Point at the QR code in Droprr on your PC or Mac (Pair a Phone).")
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(24)
                    }
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera.fill",
                                           description: Text("Allow camera access for Droprr in Settings, or scan the code with the Camera app."))
                }
            }
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !done, let value = barcode.payloadStringValue, value.lowercased().hasPrefix("droprr://pair") else { continue }
                done = true
                scanner.stopScanning()
                onCode(value)
            }
        }
    }
}
