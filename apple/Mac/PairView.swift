import SwiftUI

/// Pair a phone: the one code (docs/PROTOCOL.md, "One code") for any phone's browser and the Droprr app. Its join
/// secret is open only while this window is. Until the host page is ready, "Getting ready…" (never the older
/// pairing code, which carries the token).
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
                Text("Scan with any phone's camera.")
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
                // The host page is still starting (it reloads until it's ready): never fall back to the token code.
                VStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text("Getting ready…").font(.callout).foregroundStyle(Look.muted)
                }
                .frame(width: 268, height: 268)
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
    }

    /// A phone or browser scanned the code and connected: close at once; the Send window shows it, selected,
    /// with its usual success line.
    private func close(after name: String?) {
        guard name != nil else { return }
        dismissWindow(id: "pair")
        model.connectedBrowser = nil
        model.lastPaired = nil
    }
}
