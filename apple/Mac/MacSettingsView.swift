import SwiftUI

/// Mac Settings: this Mac, appearance, devices, receiving and the token, separated by hairlines.
struct MacSettingsView: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow
    @State private var editing: Peer?
    @State private var editingToken = false
    @State private var removing: Peer?
    @State private var pingResults: [UUID: PingResult] = [:]
    @State private var showToken = false
    @State private var showingAppearance = false

    private var settings: DroprrSettings { model.settings }

    /// The cards without the scroll view (also used for debug snapshots).
    var content: some View {
        VStack(alignment: .leading, spacing: Look.isAtelier ? 30 : Space.xl) {
            if showingAppearance {
                Button { Motion.perform { showingAppearance = false } } label: {
                    Label("Settings", systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(Look.muted)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.bottom, -Space.md)
                pageTitle("Appearance")
                VStack(alignment: .leading, spacing: Space.md) {
                    SectionHeader(title: "Light or dark", detail: Look.forcesDark ? "Spatial is always dark." : "System follows your Mac.")
                    ColorModePicker(settings: settings).frame(maxWidth: 320)
                }
                style
                appearance
            } else {
                pageTitle("Settings")
                thisMac
                appearanceLink
                devices
                receiving
                security
            }
        }
        .padding(.horizontal, Look.isAtelier ? 36 : 28)
        .padding(.top, Space.lg)
        .padding(.bottom, 36)
        .foregroundStyle(Look.ink)
        .toggleStyle(LookToggleStyle())
    }

    var body: some View {
        ScrollView { content }
        .frame(width: 580, height: 680)
        // macOS focuses the first text field (the name) when the window opens; don't.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { endEditing() } }
        .seamlessWindow()
        .lookRoot()
        .onAppear(perform: takeTokenRequest)
        .onChange(of: settings.tokenRequest) { takeTokenRequest() }
        .onChange(of: settings.colorMode) { Look.applyAppAppearance() }
        .onChange(of: settings.style) {
            // Window chrome (background, opacity, dark glass) follows the style too.
            for window in NSApp.windows { AppDelegate.hideTitleBar(window) }
        }
        .sheet(item: $editing) { peer in
            PeerEditor(peer: peer, isNew: !settings.peers.contains { $0.id == peer.id }, focusToken: editingToken,
                       onRemove: { editing = nil; removing = peer }) { saved in
                if let saved, settings.save(saved) {
                    // Switch both sides to per-device tokens, then check the connection.
                    Task {
                        await settings.exchangeTokens(with: saved)
                        if let current = settings.peers.first(where: { $0.id == saved.id }) { await ping(current) }
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
            if !Look.isAtelier { LogoBadge(size: 46) }
            VStack(alignment: .leading, spacing: Look.isAtelier ? Space.sm : 2) {
                if Look.isAtelier { Kicker("This Mac") }
                TextField("Device name", text: Binding(get: { settings.deviceName }, set: { settings.deviceName = $0 }))
                    .textFieldStyle(.plain)
                    .font(Look.isAtelier ? Look.display(26) : Look.display(18, weight: Look.style == .clay ? .heavy : .semibold))
                    .accessibilityLabel("Device name")
                    .onSubmit(endEditing)
                HStack(spacing: 7) {
                    StatusDot(on: model.isListening)
                    Text(model.isListening ? "Ready to receive" : "Not receiving")
                }
                .font(.system(size: 12))
                .foregroundStyle(Look.muted)
            }
            Spacer()
            Button {
                openWindow(id: "pair")
                bringToFront()
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "qrcode").foregroundStyle(Look.isAtelier ? Theme.end : .primary)
                    Text("Pair a phone")
                }
            }
            .buttonStyle(PrimaryStyle())
            .hoverHint("Show a QR code for your iPhone to scan")
        }
        .lookCard()
    }

    private func pageTitle(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 6) {
                if Look.isAtelier { Kicker("Droprr") }
                Text(title).font(Look.display(Look.isAtelier ? 38 : 32))
            }
            Hairline()
        }
    }

    /// Opens the Appearance page (style and colors).
    private var appearanceLink: some View {
        Button { Motion.perform { showingAppearance = true } } label: {
            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Image(systemName: "paintpalette").font(.system(size: 17)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Appearance").font(.system(size: 14, weight: .semibold))
                        Text("\(Look.style.name) · \(ThemePalette.named(settings.theme).name)")
                            .font(.system(size: 12)).foregroundStyle(Look.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Look.muted)
                }
                .padding(.vertical, Look.isAtelier ? Space.md : 0)
                Hairline()
            }
            .lookCard(padding: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHint("Style and colors")
    }

    /// Opens the device that a "Missing Token" button elsewhere asked for.
    private func takeTokenRequest() {
        guard let id = settings.tokenRequest, let peer = settings.peers.first(where: { $0.id == id }) else { return }
        settings.tokenRequest = nil
        showingAppearance = false
        editingToken = true
        editing = peer
    }

    /// Return (or opening the window) leaves no field focused, so no cursor lingers.
    private func endEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var style: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Style", detail: "How Droprr's windows look.")
            StylePicker(settings: settings)
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Colors", detail: "Each theme has light and dark colors.")
            ThemePicker(settings: settings)
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Devices", detail: settings.peers.isEmpty ? "None yet" : "\(settings.peers.count) paired") {
                Button("Add device") { editingToken = false; editing = Peer(name: "", host: "") }
                    .buttonStyle(SecondaryStyle())
            }
            VStack(alignment: .leading, spacing: 0) {
            if settings.peers.isEmpty {
                RowSeparator()
                Text("Pair your iPhone with the QR code above, or add your PC by its Tailscale name.")
                    .font(.system(size: 12)).foregroundStyle(Look.muted)
                    .padding(.vertical, Space.md)
            }
            ForEach(settings.peers) { peer in
                RowSeparator()
                DeviceRow(peer: peer, result: pingResults[peer.id],
                          onTest: { Task { await ping(peer) } },
                          onEdit: { editingToken = false; editing = peer },
                          onRemove: { removing = peer },
                          onFixToken: { editingToken = true; editing = peer })
                    .padding(.vertical, Space.md)
            }
            Hairline()
            }
            .lookCard(list: true)
        }
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader(title: "Receiving", detail: "Files go to Downloads › Droprr") {
                Button("Open folder") {
                    try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MacModel.inbox)
                }
                .buttonStyle(SecondaryStyle())
            }
            VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Copy received text and links",
                       detail: "Clipboard managers are asked not to keep them.") {
                Toggle("Copy received text and links", isOn: Binding(get: { settings.copyTextAndLinks }, set: { settings.copyTextAndLinks = $0 }))
                    .labelsHidden()
            }
            SettingRow(title: "Copy everything received",
                       detail: "Includes files and images, as they arrive.") {
                Toggle("Copy everything received", isOn: Binding(get: { settings.autoCopy }, set: { settings.autoCopy = $0 }))
                    .labelsHidden()
            }
            SettingRow(title: "Open at login", detail: "Keep receiving without opening the app.") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .labelsHidden()
            }
            SettingRow(title: "Port", detail: "Other devices send here. 53318 is the default.") {
                TextField("", value: Binding(get: { settings.port }, set: { settings.port = $0 }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onSubmit { model.restartIfNeeded(); endEditing() }
                    .accessibilityLabel("Port")
            }
            Hairline()
            }
            .lookCard(list: true)
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
                .onSubmit(endEditing)
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .foregroundStyle(Look.muted)
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                    .hoverHint(showToken ? "Hide the token" : "Show the token")
                Button("Copy") { Clipboard.copy(text: settings.token) }
                    .buttonStyle(SecondaryStyle())
                    .disabled(settings.token.isEmpty)
                Button("New token") { settings.token = DroprrSettings.generateToken() }
                    .buttonStyle(SecondaryStyle())
                    .hoverHint("Paired devices will need to pair again")
            }
            .lookCard(padding: 14)
        }
    }

    private func ping(_ peer: Peer) async {
        pingResults[peer.id] = .checking
        pingResults[peer.id] = await settings.ping(peer)
    }
}

private struct DeviceRow: View {
    var peer: Peer
    var result: PingResult?
    var onTest: () -> Void
    var onEdit: () -> Void
    var onRemove: () -> Void
    var onFixToken: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: Theme.symbol(for: peer))
                .font(.system(size: 14))
                .foregroundStyle(Look.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(peer.name).font(Look.display(18))
                    Text(Theme.platformName(peer.platform).uppercased())
                        .font(.system(size: 9.5, weight: .semibold)).tracking(1.4)
                        .foregroundStyle(Look.muted)
                }
                Group {
                    if peer.isPhone {
                        Text("Collects items when Droprr opens on it").font(.system(size: 11))
                    } else {
                        Text("\(peer.host):\(String(peer.port))").font(.system(size: 11).monospaced())
                    }
                }
                .foregroundStyle(Look.muted).lineLimit(1)
                status
                if !peer.isPaired { MissingTokenButton(action: onFixToken) }
            }
            Spacer()
            if !peer.isPhone {
                Button("Test", action: onTest)
                    .buttonStyle(SecondaryStyle())
                    .hoverHint("Check that \(peer.name) answers")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(Look.muted)
                .accessibilityLabel("Edit \(peer.name)")
                .hoverHint("Edit or rename")
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(Look.muted)
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
        case .checking: Label("Checking…", systemImage: "ellipsis").font(.system(size: 11)).foregroundStyle(Look.muted)
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
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Look.muted) }
            }
            Spacer()
            accessory()
        }
    }
}
