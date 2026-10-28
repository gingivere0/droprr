import CoreImage.CIFilterBuiltins
import SwiftUI

/// Shows this Mac's pairing QR code for the iPhone to scan.
struct PairView: View {
    @Bindable var model: MacModel
    @State private var address = PairingInfo.tailscaleAddress()
    @State private var revealed = false

    private var pairing: PairingInfo? {
        guard let address, !model.settings.token.isEmpty else { return nil }
        return PairingInfo(name: model.settings.deviceName, host: address, port: model.settings.port,
                           token: model.settings.token, platform: DroprrSettings.platform)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                LogoBadge(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pair a Phone").font(.title3.weight(.semibold))
                    Text("Scan with the Camera app or Droprr on your iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if model.settings.token.isEmpty {
                problem("Set a pairing token first.", button: "Generate Token") {
                    model.settings.token = DroprrSettings.generateToken()
                }
            } else if address == nil {
                problem("Tailscale isn't connected on this Mac, so the phone couldn't reach it.", button: "Check Again") {
                    address = PairingInfo.tailscaleAddress()
                }
            } else if let pairing, let url = pairing.url {
                ZStack {
                    QRCodeImage(text: url.absoluteString)
                        .frame(width: 240, height: 240)
                        .blur(radius: revealed ? 0 : 14)
                    if !revealed {
                        Button("Show Code") { revealed = true }
                            .buttonStyle(HoverButtonStyle(.prominent))
                            .hoverHint("The code contains your pairing token, so only show it when you're ready to scan")
                    }
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)

                VStack(spacing: 2) {
                    Text(pairing.name).font(.headline)
                    Text("\(pairing.host):\(String(pairing.port))").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Label("This code contains this Mac's pairing token. Only show it to your own phone.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func problem(_ message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(HoverButtonStyle(.prominent))
        }
        .padding(.vertical, 30)
    }
}

private struct QRCodeImage: View {
    var text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
