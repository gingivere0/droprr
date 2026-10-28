import SwiftUI

/// Shows this Mac's pairing QR code for the iPhone to scan.
struct PairView: View {
    @Bindable var model: MacModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: Space.lg) {
            HStack(spacing: Space.md) {
                LogoBadge(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pair a Phone").font(.title3.weight(.semibold))
                    Text("Scan with the Camera app or Droprr on your iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            PairingQRCode(settings: model.settings)
            Label("This code contains this Mac's pairing token. Only show it to your own phone.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .frame(width: 340)
        .background { Theme.surface.ignoresSafeArea() }
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
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.gradient)
                    Text("Paired with \(name)").font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .transition(.opacity)
            }
        }
        .motion(Motion.standard, value: model.lastPaired)
    }
}
