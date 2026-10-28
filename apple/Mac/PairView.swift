import SwiftUI

/// Shows this Mac's pairing QR code for the iPhone to scan.
struct PairView: View {
    @Bindable var model: MacModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker("Droprr")
                        Text("Pair a phone").font(Atelier.serif(30))
                    }
                    Spacer()
                    LogoBadge(size: 30).padding(.bottom, 4)
                }
                Hairline()
                Text("Scan with the Camera app or Droprr on your iPhone.")
                    .font(.system(size: 12)).foregroundStyle(Atelier.muted)
            }

            PairingQRCode(settings: model.settings)
            Label("This code contains this Mac's pairing token. Only show it to your own phone.", systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Atelier.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
        .padding(.top, Space.lg)
        .padding(.bottom, 30)
        .foregroundStyle(Atelier.ink)
        .frame(width: 340)
        .background { Atelier.paper.ignoresSafeArea() }
        .seamlessWindow()
        .onAppear { model.lastPaired = nil }
        .onChange(of: model.lastPaired) { _, name in
            // A phone scanned the code and introduced itself: confirm, then close.
            guard name != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismissWindow(id: "pair")
            }
        }
        .overlay {
            if let name = model.lastPaired {
                VStack(spacing: Space.md) {
                    Image(systemName: "checkmark").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.end)
                    Text("Paired with \(name)").font(Atelier.serif(24))
                }
                .foregroundStyle(Atelier.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Atelier.paper)
                .transition(.opacity)
            }
        }
        .motion(Motion.standard, value: model.lastPaired)
    }
}
