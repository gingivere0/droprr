import SwiftUI

/// "Open in a browser": a QR code a phone's camera opens, signed in with a one-time code
/// (docs/PROTOCOL.md, "Browser access"). The code exists only while this window is open.
struct BrowserAccessView: View {
    @Bindable var model: MacModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// 0: the website (no warning, any phone on this Wi-Fi), 1: this Mac's own page over Wi-Fi, 2: over Tailscale.
    @State private var choice = 0
    private var useTailscale: Bool { choice == 2 }
    @State private var code = ""

    private var wifiAddress: String? {
        LocalAddresses.lan(port: model.settings.port + 2).first { !$0.hasPrefix("[") }.map { "https://\($0)/web" }
    }
    private var tailscaleAddress: String? {
        PairingInfo.tailscaleAddress().map { "http://\($0):\(model.settings.port)/web" }
    }
    private var address: String? { choice == 0 ? nil : useTailscale ? tailscaleAddress : wifiAddress }

    /// What the QR code holds: the website's join link, or this Mac's page with the code in the fragment.
    private var qrText: String? {
        _ = model.browserHostVersion
        if choice == 0 { return model.browserHost.joinLink }
        return address.map { "\($0)#\(code)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Open in a browser").font(Look.display(Look.isAtelier ? 30 : 24))
            Picker("Network", selection: $choice) {
                Text("Website").tag(0)
                Text("Wi-Fi").tag(1)
                Text("Tailscale").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if choice == 0 {
                if let link = qrText {
                    HStack {
                        Spacer()
                        QRCodeImage(text: link)
                            .frame(width: 200, height: 200)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        Spacer()
                    }
                    Text("Scan with the phone's camera. It opens the Droprr website, which connects straight to this Mac over this Wi-Fi. No app, no warning, and any number of phones while this window is open.")
                        .font(.system(size: 11)).foregroundStyle(Look.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Getting ready…").font(.callout).foregroundStyle(Look.muted)
                }
            } else if let address, !code.isEmpty {
                HStack {
                    Spacer()
                    QRCodeImage(text: "\(address)#\(code)")
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(address).font(.system(size: 12).monospaced()).textSelection(.enabled)
                    Text("Code: \(BrowserAccess.format(code))").font(.system(size: 15, weight: .semibold).monospaced())
                        .textSelection(.enabled)
                }
                Text(useTailscale
                     ? "Scan with the phone's camera. The phone needs Tailscale on."
                     : "Scan with the phone's camera. The first time, the browser warns that the connection isn't private: tap Show Details, then visit the website. That's this Mac's own certificate.")
                    .font(.system(size: 11)).foregroundStyle(Look.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if address == nil {
                Text(useTailscale ? "Tailscale isn't connected on this Mac." : "This Mac isn't on a private Wi-Fi network, or Local network is off.")
                    .font(.callout).foregroundStyle(Look.muted)
            }

            if model.browserCodeClosed {
                Text("Too many wrong codes. Choose New Code to try again.").font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Button("New Code") { newCode() }
                    .buttonStyle(SecondaryStyle())
                Spacer()
            }
        }
        .padding(28)
        .frame(width: 360)
        .seamlessWindow()
        .lookRoot()
        .overlay {
            if let name = model.connectedBrowser {
                VStack(spacing: Space.md) {
                    Image(systemName: "checkmark").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.end)
                    Text("Connected \(name)").font(Look.display(22))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { LookBackground() }
            }
        }
        .onAppear {
            newCode()
        }
        .onDisappear {
            model.browserAccess.close()
            model.browserHost.configChanged()
            code = ""
        }
        .onChange(of: model.connectedBrowser) { _, name in
            guard name != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismissWindow(id: "browser")
                model.connectedBrowser = nil
            }
        }
    }

    private func newCode() {
        model.browserCodeClosed = false
        model.connectedBrowser = nil
        code = model.browserAccess.open()
        model.browserHost.configChanged()   // the host page learns the new join secret
    }
}
