import SwiftUI

struct MacSettingsView: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsForm(settings: model.settings) {
            Toggle("Open Droprr at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Button {
                openWindow(id: "pair")
                bringToFront()
            } label: {
                Label("Pair a Phone with a QR Code…", systemImage: "qrcode")
            }
            .buttonStyle(HoverButtonStyle(.bordered, compact: true))
        }
        .frame(width: 480, height: 600)
    }
}
