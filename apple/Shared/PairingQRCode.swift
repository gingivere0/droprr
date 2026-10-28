#if os(macOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// This Mac's pairing QR code, blurred until revealed because it contains the token.
/// Shown in the Pair a Phone window and on the Add Device screen.
struct PairingQRCode: View {
    var settings: DroprrSettings
    var size: CGFloat = 240
    @State private var revealed = false
    @State private var address = PairingInfo.tailscaleAddress()

    var body: some View {
        if settings.token.isEmpty {
            Text("Set this Mac's token in Settings to show a pairing code.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let address, let url = PairingInfo(name: settings.deviceName, host: address, port: settings.port,
                                                     token: settings.token, platform: DroprrSettings.platform).url {
            VStack(spacing: 8) {
                ZStack {
                    QRCodeImage(text: url.absoluteString)
                        .frame(width: size, height: size)
                        .blur(radius: revealed ? 0 : size * 0.06)
                    if !revealed {
                        Button("Show Code") { revealed = true }
                            .buttonStyle(HoverButtonStyle(.prominent))
                            .hoverHint("The code contains this Mac's token, so only show it when you're ready to scan")
                    }
                }
                .padding(size * 0.06)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                Text("\(address):\(String(settings.port))").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 8) {
                Text("Tailscale isn't connected on this Mac, so a phone couldn't reach it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Check Again") { address = PairingInfo.tailscaleAddress() }
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
            }
        }
    }
}

struct QRCodeImage: View {
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
#endif
