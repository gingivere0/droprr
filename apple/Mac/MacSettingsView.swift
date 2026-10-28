import SwiftUI

struct MacSettingsView: View {
    @Bindable var model: MacModel

    var body: some View {
        SettingsForm(settings: model.settings) {
            Toggle("Open Droprr at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }
        .frame(width: 480, height: 600)
    }
}
