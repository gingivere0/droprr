import SwiftUI

/// Mac Settings as a set of cards: this Mac, devices, receiving, and security.
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
        VStack(alignment: .leading, spacing: Space.md) {
            thisMac
            appearance
            devices
            receiving
            security
        }
        .padding(Space.xl)
    }

    var body: some View {
        ScrollView { content }
        .frame(width: 580, height: 680)
        .background { Theme.surface.ignoresSafeArea() }
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

    // MARK: Cards

    private var thisMac: some View {
        HStack(spacing: Space.lg) {
            GradientTile(symbol: "laptopcomputer", size: 64, glowing: true)
            VStack(alignment: .leading, spacing: Space.sm) {
                TextField("Device name", text: Binding(get: { settings.deviceName }, set: { settings.deviceName = $0 }))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))
                    .accessibilityLabel("Device name")
                HStack(spacing: Space.sm) {
                    Pill(text: model.isListening ? "Ready to receive" : "Not receiving",
                         symbol: model.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                         color: model.isListening ? .green : .orange)
                    Pill(text: "Port \(String(settings.port))", symbol: "network")
                }
            }
            Spacer()
            Button {
                openWindow(id: "pair")
                bringToFront()
            } label: {
                Label("Pair a Phone", systemImage: "qrcode").fontWeight(.semibold)
            }
            .buttonStyle(HoverButtonStyle(.prominent))
            .shadow(color: Theme.start.opacity(0.3), radius: 8, y: 3)
            .hoverHint("Show a QR code for your iPhone to scan")
        }
        .card()
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CardHeader(symbol: "paintpalette.fill", color: Theme.start, glyph: Theme.onAccent, title: "Appearance",
                       subtitle: "Color theme. Light and dark follow your Mac.")
            ThemePicker(settings: settings)
        }
        .card()
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CardHeader(symbol: "point.3.connected.trianglepath.dotted", color: Theme.start, glyph: Theme.onAccent, title: "Devices",
                       subtitle: settings.peers.isEmpty ? "None yet" : "\(settings.peers.count) paired") {
                Button { editing = Peer(name: "", host: "") } label: {
                    Label("Add Device", systemImage: "plus")
                }
                .buttonStyle(HoverButtonStyle(.bordered, compact: true))
            }
            if settings.peers.isEmpty {
                Text("Pair your iPhone with the QR code above, or add your PC by its Tailscale name.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(settings.peers) { peer in
                Divider()
                DeviceRow(peer: peer, result: pingResults[peer.id],
                          onTest: { Task { await ping(peer) } },
                          onEdit: { editing = peer },
                          onRemove: { removing = peer })
            }
        }
        .card()
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CardHeader(symbol: "tray.and.arrow.down.fill", color: Theme.secondaryText, glyph: Theme.tile, title: "Receiving",
                       subtitle: "Files go to Downloads › Droprr") {
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MacModel.inbox)
                }
                .buttonStyle(HoverButtonStyle(.bordered, compact: true))
            }
            Divider()
            OptionRow(title: "Copy received text and links to the clipboard",
                      detail: "Paste them right away. Clipboard managers are asked not to keep them.") {
                Toggle("", isOn: Binding(get: { settings.copyTextAndLinks }, set: { settings.copyTextAndLinks = $0 }))
            }
            Divider()
            OptionRow(title: "Auto-copy received items to clipboard",
                      detail: "Copies everything as it arrives, including files and images.") {
                Toggle("", isOn: Binding(get: { settings.autoCopy }, set: { settings.autoCopy = $0 }))
            }
            Divider()
            OptionRow(title: "Open Droprr at login", detail: "Keep receiving without opening the app.") {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Divider()
            OptionRow(title: "Port", detail: "Other devices send here. 53318 is the default.") {
                TextField("", value: Binding(get: { settings.port }, set: { settings.port = $0 }),
                          format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onSubmit { model.restartIfNeeded() }
                    .accessibilityLabel("Port")
            }
        }
        .card()
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CardHeader(symbol: "lock.fill", color: .gray, title: "This Mac's token",
                       subtitle: "Devices need it to send here. The Pair a Phone code includes it.")
            HStack(spacing: Space.sm) {
                Group {
                    if showToken {
                        TextField("Token", text: Binding(get: { settings.token }, set: { settings.token = $0 }))
                    } else {
                        SecureField("Token", text: Binding(get: { settings.token }, set: { settings.token = $0 }))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel("Token")
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                    .hoverHint(showToken ? "Hide the token" : "Show the token")
                Button("Copy") { Clipboard.copy(text: settings.token) }
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                    .disabled(settings.token.isEmpty)
                Button("Generate New") { settings.token = DroprrSettings.generateToken() }
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                    .hoverHint("Paired devices will need to pair again")
            }
        }
        .card()
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
        HStack(spacing: Space.md) {
            GradientTile(symbol: Theme.symbol(for: peer), size: 36)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(peer.name).font(.headline)
                    Pill(text: Theme.platformName(peer.platform))
                }
                Group {
                    if peer.isPhone {
                        Text("Collects items when Droprr opens on it").font(.caption)
                    } else {
                        Text("\(peer.host):\(String(peer.port))").font(.caption.monospaced())
                    }
                }
                .foregroundStyle(.secondary).lineLimit(1)
                status
                if !peer.isPaired {
                    Label("Not paired: scan its code or enter its token", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !peer.isPhone {
                Button("Test", action: onTest)
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                    .hoverHint("Check that \(peer.name) answers")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(HoverButtonStyle(.plain))
                .accessibilityLabel("Edit \(peer.name)")
                .hoverHint("Edit or rename")
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(.red)
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
        case .checking: Label("Checking…", systemImage: "ellipsis").font(.caption2).foregroundStyle(.secondary)
        case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        case nil: EmptyView()
        }
    }
}

/// A settings line: title and explanation on the left, a control on the right.
private struct OptionRow<Control: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control().labelsHidden().toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
    }
}
