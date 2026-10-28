import SwiftUI

/// Mac Settings: this Mac, appearance, devices, receiving and the token, separated by hairlines.
struct MacSettingsView: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow
    @State private var editing: Peer?
    @State private var removing: Peer?
    @State private var pingResults: [UUID: PingResult] = [:]
    @State private var showToken = false

    private var settings: DroprrSettings { model.settings }

    /// The cards without the scroll view (also used for debug snapshots).
    var content: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker("Droprr")
                    Text("Settings").font(Atelier.serif(38))
                }
                Hairline()
            }
            thisMac
            appearance
            devices
            receiving
            security
        }
        .padding(.horizontal, 36)
        .padding(.top, Space.lg)
        .padding(.bottom, 36)
        .foregroundStyle(Atelier.ink)
        .toggleStyle(AtelierToggleStyle())
    }

    var body: some View {
        ScrollView { content }
        .frame(width: 580, height: 680)
        .background { Atelier.paper.ignoresSafeArea() }
        .seamlessWindow()
        .sheet(item: $editing) { peer in
            PeerEditor(peer: peer, isNew: !settings.peers.contains { $0.id == peer.id },
                       onRemove: { editing = nil; removing = peer }) { saved in
                if let saved {
                    let tokenChanged = settings.peers.first { $0.id == saved.id }?.token != saved.token
                    if let i = settings.peers.firstIndex(where: { $0.id == saved.id }) {
                        settings.peers[i] = saved
                    } else {
                        settings.peers.append(saved)
                    }
                    if tokenChanged {
                        // Switch both sides to per-device tokens, then check the connection.
                        Task {
                            await settings.exchangeTokens(with: saved)
                            if let current = settings.peers.first(where: { $0.id == saved.id }) { await ping(current) }
                        }
                    }
                }
                editing = nil
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "device")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let peer = removing { settings.peers.removeAll { $0.id == peer.id } }
                removing = nil
            }
        } message: {
            Text(removing?.isPhone == true
                 ? "If the iPhone checks in again, it's added back."
                 : "You can add it again later with its Tailscale name.")
        }
    }

    // MARK: Sections

    private var thisMac: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Kicker("This Mac")
                TextField("Device name", text: Binding(get: { settings.deviceName }, set: { settings.deviceName = $0 }))
                    .textFieldStyle(.plain)
                    .font(Atelier.serif(26))
                    .accessibilityLabel("Device name")
                HStack(spacing: 7) {
                    StatusDot(on: model.isListening)
                    Text(model.isListening ? "Ready to receive" : "Not receiving")
                }
                .font(.system(size: 12))
                .foregroundStyle(Atelier.muted)
            }
            Spacer()
            Button {
                openWindow(id: "pair")
                bringToFront()
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "qrcode").foregroundStyle(Theme.end)
                    Text("Pair a phone")
                }
            }
            .buttonStyle(AtelierPrimaryStyle())
            .hoverHint("Show a QR code for your iPhone to scan")
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Theme", detail: "Light and dark follow your Mac.")
            ThemePicker(settings: settings)
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Devices", detail: settings.peers.isEmpty ? "None yet" : "\(settings.peers.count) paired") {
                Button("Add device") { editing = Peer(name: "", host: "") }
                    .buttonStyle(AtelierLinkStyle())
            }
            .padding(.bottom, Space.md)
            if settings.peers.isEmpty {
                Hairline()
                Text("Pair your iPhone with the QR code above, or add your PC by its Tailscale name.")
                    .font(.system(size: 12)).foregroundStyle(Atelier.muted)
                    .padding(.vertical, Space.md)
            }
            ForEach(settings.peers) { peer in
                Hairline()
                DeviceRow(peer: peer, result: pingResults[peer.id],
                          onTest: { Task { await ping(peer) } },
                          onEdit: { editing = peer },
                          onRemove: { removing = peer })
                    .padding(.vertical, Space.md)
            }
            Hairline()
        }
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Receiving", detail: "Files go to Downloads › Droprr") {
                Button("Open folder") {
                    try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MacModel.inbox)
                }
                .buttonStyle(AtelierLinkStyle())
            }
            .padding(.bottom, Space.md)
            AtelierRow(title: "Copy received text and links",
                       detail: "Clipboard managers are asked not to keep them.") {
                Toggle("Copy received text and links", isOn: Binding(get: { settings.copyTextAndLinks }, set: { settings.copyTextAndLinks = $0 }))
                    .labelsHidden()
            }
            AtelierRow(title: "Copy everything received",
                       detail: "Includes files and images, as they arrive.") {
                Toggle("Copy everything received", isOn: Binding(get: { settings.autoCopy }, set: { settings.autoCopy = $0 }))
                    .labelsHidden()
            }
            AtelierRow(title: "Open at login", detail: "Keep receiving without opening the app.") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .labelsHidden()
            }
            AtelierRow(title: "Port", detail: "Other devices send here. 53318 is the default.") {
                TextField("", value: Binding(get: { settings.port }, set: { settings.port = $0 }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onSubmit { model.restartIfNeeded() }
                    .accessibilityLabel("Port")
            }
            Hairline()
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Token", detail: "Devices need it to send here. The pairing code includes it.")
            HStack(spacing: Space.md) {
                Group {
                    if showToken {
                        TextField("Token", text: Binding(get: { settings.token }, set: { settings.token = $0 }))
                    } else {
                        SecureField("Token", text: Binding(get: { settings.token }, set: { settings.token = $0 }))
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13).monospaced())
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Hairline() }
                .accessibilityLabel("Token")
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .foregroundStyle(Atelier.muted)
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                    .hoverHint(showToken ? "Hide the token" : "Show the token")
                Button("Copy") { Clipboard.copy(text: settings.token) }
                    .buttonStyle(AtelierLinkStyle())
                    .disabled(settings.token.isEmpty)
                Button("New token") { settings.token = DroprrSettings.generateToken() }
                    .buttonStyle(AtelierLinkStyle())
                    .hoverHint("Paired devices will need to pair again")
            }
        }
    }

    private func ping(_ peer: Peer) async {
        pingResults[peer.id] = .checking
        do {
            let info = try await DroprrClient(peer: peer).ping()
            pingResults[peer.id] = .ok("\(Theme.platformName(info.platform)) · v\(info.version)")
            if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                settings.peers[i].platform = info.platform
                settings.peers[i].remoteName = info.name
            }
        } catch {
            pingResults[peer.id] = .failed(error.localizedDescription)
        }
    }
}

private struct DeviceRow: View {
    var peer: Peer
    var result: PingResult?
    var onTest: () -> Void
    var onEdit: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: Theme.symbol(for: peer))
                .font(.system(size: 14))
                .foregroundStyle(Atelier.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(peer.name).font(Atelier.serif(18))
                    Text(Theme.platformName(peer.platform).uppercased())
                        .font(.system(size: 9.5, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Atelier.muted)
                }
                Group {
                    if peer.isPhone {
                        Text("Collects items when Droprr opens on it").font(.system(size: 11))
                    } else {
                        Text("\(peer.host):\(String(peer.port))").font(.system(size: 11).monospaced())
                    }
                }
                .foregroundStyle(Atelier.muted).lineLimit(1)
                status
                if !peer.isPaired {
                    Label("Not paired: scan its code or enter its token", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !peer.isPhone {
                Button("Test", action: onTest)
                    .buttonStyle(AtelierLinkStyle())
                    .hoverHint("Check that \(peer.name) answers")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(Atelier.muted)
                .accessibilityLabel("Edit \(peer.name)")
                .hoverHint("Edit or rename")
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(Atelier.muted)
                .accessibilityLabel("Remove \(peer.name)")
                .hoverHint("Remove this device")
        }
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove \(peer.name)", role: .destructive, action: onRemove)
        }
    }

    @ViewBuilder private var status: some View {
        switch result {
        case .checking: Label("Checking…", systemImage: "ellipsis").font(.system(size: 11)).foregroundStyle(Atelier.muted)
        case .ok(let text): Label(text, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Theme.successText)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case nil: EmptyView()
        }
    }
}

/// A section label in spaced capitals, a short note, and an optional action on the right.
private struct SectionHeader<Accessory: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, detail: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(title)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Atelier.muted) }
            }
            Spacer()
            accessory()
        }
    }
}
