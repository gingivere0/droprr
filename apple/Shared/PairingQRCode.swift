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
    @State private var lan = LocalAddresses.lan(port: DroprrSettings.shared.tlsPort)

    /// Tailscale when it's connected; otherwise this Mac's first LAN address (HTTPS only, pinned by fp).
    private var host: String? {
        address ?? (settings.localNetwork ? lan.first.map(PairingInfo.hostPart) : nil)
    }

    var body: some View {
        if settings.token.isEmpty {
            Text("Set this Mac's token in Settings to show a pairing code.")
                .font(.callout).foregroundStyle(.secondary)
        } else if let host, let url = PairingInfo(name: settings.deviceName, host: host, port: settings.port,
                                                  token: settings.token, platform: DroprrSettings.platform,
                                                  id: settings.deviceID, fp: settings.localNetwork ? settings.identity?.fingerprint : nil,
                                                  lan: settings.localNetwork ? lan : []).url {
            VStack(spacing: Space.sm) {
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
                .background(.white, in: RoundedRectangle(cornerRadius: Radius.feature, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                Text(address.map { "\($0):\(String(settings.port))" } ?? "Wi-Fi only: \(host)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: Space.sm) {
                Text("This Mac isn't on Tailscale or a private Wi-Fi network, so a phone couldn't reach it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Check Again") {
                    address = PairingInfo.tailscaleAddress()
                    lan = LocalAddresses.lan(port: settings.tlsPort)
                }
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
