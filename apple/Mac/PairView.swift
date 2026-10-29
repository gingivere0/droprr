import SwiftUI

/// Pair a phone: the one code (docs/PROTOCOL.md, "One code") for any phone's browser and the Droprr app. Its join
/// secret is open only while this window is. Without the website (the host page isn't ready), the older pairing
/// code, which carries the token.
struct PairView: View {
    @Bindable var model: MacModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var revealed = false

    private var oneCode: String? {
        _ = model.browserHostVersion
        return model.browserHost.joinLink
    }

    var body: some View {
        VStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if Look.isAtelier { Kicker("Droprr") }
                        Text("Pair a phone").font(Look.display(30))
                    }
                    Spacer()
                    LogoBadge(size: 30).padding(.bottom, 4)
                }
                Hairline()
                Text(oneCode == nil ? "Scan with the Camera app or Droprr on your iPhone." : "Scan with any phone's camera.")
                    .font(.system(size: 12)).foregroundStyle(Look.muted)
            }

            if let oneCode {
                ZStack {
                    QRCodeImage(text: oneCode)
                        .frame(width: 240, height: 240)
                        .blur(radius: revealed ? 0 : 28)
                    if !revealed {
                        Button("Click to show the code") { revealed = true }
                            .buttonStyle(HoverButtonStyle(.prominent))
                    }
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: Radius.feature, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                .contentShape(Rectangle())
                .onTapGesture { revealed = true }
                VStack(alignment: .leading, spacing: 4) {
                    Label("Anyone who scans this can connect", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("While this window is open, any phone that scans the code can send to this Mac and receive from it. You can remove a device later in Settings.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Look.muted)
            } else {
                PairingQRCode(settings: model.settings)
                Label("This code contains this Mac's pairing token. Only show it to your own phone.", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(Look.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, Space.lg)
        .padding(.bottom, 30)
        .foregroundStyle(Look.ink)
        .frame(width: 340)
        .seamlessWindow()
        .lookRoot()
        .onAppear {
            revealed = false
            model.openOneCode()
        }
        .onDisappear { model.closeOneCode() }
        .onChange(of: model.lastPaired) { _, name in close(after: name) }
        .onChange(of: model.connectedBrowser) { _, name in close(after: name) }
        .overlay {
            if let name = model.lastPaired ?? model.connectedBrowser {
                VStack(spacing: Space.md) {
                    Image(systemName: "checkmark").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.end)
                    Text("Paired with \(name)").font(Look.display(24))
                }
                .foregroundStyle(Look.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { LookBackground() }
                .transition(.opacity)
            }
        }
        .motion(Motion.standard, value: model.lastPaired ?? model.connectedBrowser)
    }

    /// A phone or browser scanned the code and connected: confirm, then close.
    private func close(after name: String?) {
        guard name != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            dismissWindow(id: "pair")
            model.connectedBrowser = nil
        }
    }
}
