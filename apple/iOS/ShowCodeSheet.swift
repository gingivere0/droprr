import CoreImage.CIFilterBuiltins
import SwiftUI

private struct ShowCodeKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Opens this phone's code (Settings › Devices).
    var showCode: () -> Void {
        get { self[ShowCodeKey.self] }
        set { self[ShowCodeKey.self] = newValue }
    }
}

/// This phone's own code, for another iPhone to scan in Droprr or any phone's camera (docs/PROTOCOL.md, "Phones as
/// hosts"). Blurred until tapped, valid while this is open, for at most 10 minutes. Closes once a device connects.
struct ShowCodeSheet: View {
    @Bindable var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var failed = false
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.xl) {
                Text("Scan with Droprr on another iPhone, or any phone's camera.")
                    .font(.subheadline).foregroundStyle(Look.muted).multilineTextAlignment(.center)
                if let code, let image = Self.qr(code) {
                    Button { revealed = true } label: {
                        ZStack {
                            Image(uiImage: image)
                                .interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .blur(radius: revealed ? 0 : 28)
                                .padding(14)
                                .background(.white, in: RoundedRectangle(cornerRadius: Radius.feature, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous))
                            if !revealed {
                                Text("Tap to show the code")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                                    .foregroundStyle(Theme.onPrimaryButton)
                                    .background(Theme.primaryButton, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealed ? "QR code" : "Show the code")
                    Text("Anyone who scans this can connect while it's open.")
                        .font(.caption).foregroundStyle(Look.muted).multilineTextAlignment(.center)
                } else if failed {
                    Text("Couldn't make a code. Check your connection and try again.")
                        .font(.callout).foregroundStyle(Look.muted).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                    Text("Getting ready…").font(.callout).foregroundStyle(Look.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LookBackground().ignoresSafeArea() }
            .foregroundStyle(Look.ink)
            .navigationTitle("Show QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task {
            code = await model.openCode()
            failed = code == nil
            try? await Task.sleep(for: .seconds(10 * 60))
            if !Task.isCancelled { dismiss() }
        }
        .onDisappear { model.closeCode() }
        .onChange(of: model.justAdded) { dismiss() }
    }

    private static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
