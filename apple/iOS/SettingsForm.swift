import SwiftUI

/// The iPhone Settings tab: appearance, devices, the default token and this device.
struct SettingsForm: View {
    @Bindable var settings: DroprrSettings
    @State private var editing: Peer?
    @State private var editingToken = false
    @State private var pingResults: [UUID: PingResult] = [:]
    @State private var showToken = false
    @State private var removing: Peer?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AppearanceSettings(settings: settings)
                } label: {
                    LabeledContent {
                        Text("\(LookStyle(rawValue: settings.style)?.name ?? "") · \(ThemePalette.named(settings.theme).name)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                }
            }
            Section {
                ForEach(settings.peers) { peer in
                    PeerRow(peer: peer, result: pingResults[peer.id],
                            onTest: { Task { await ping(peer) } },
                            onEdit: { editing = peer },
                            onRemove: { removing = peer },
                            onFixToken: { editToken(peer) })
                        .contextMenu {
                            Button("Edit…") { editing = peer }
                            Button("Remove \(peer.name)", role: .destructive) { removing = peer }
                        }
                }
                .onDelete { settings.peers.remove(atOffsets: $0) }
                Button {
                    editingToken = false
                    editing = Peer(name: "", host: "")
                } label: {
                    Label("Add Device", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Devices")
            } footer: {
                Text("Use each computer's Tailscale name (e.g. my-pc) or 100.x address. iPhones add themselves the first time they check in.")
            }

            Section {
                HStack {
                    Group {
                        if showToken {
                            TextField("Pairing token", text: $settings.token)
                        } else {
                            SecureField("Pairing token", text: $settings.token)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                .buttonStyle(.borderless)
                }
                HStack {
                    Button("Generate New") { settings.token = DroprrSettings.generateToken() }
                    Spacer()
                    Button("Copy") { Clipboard.copy(text: settings.token) }
                        .disabled(settings.token.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Default token")
            } footer: {
                Text("Used only for devices you add by hand. Devices paired with a QR code keep their own token.")
            }

            Section {
                TextField("Device name", text: $settings.deviceName)
                Toggle("Auto-copy received items to clipboard", isOn: $settings.autoCopy)
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
            } header: {
                Text("This device")
            } footer: {
                Text("Other devices see this name. Port \(String(DroprrDefaults.port)) is the default.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { LookBackground().ignoresSafeArea() }
        .confirmationDialog("Remove \(removing?.name ?? "device")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let peer = removing { settings.peers.removeAll { $0.id == peer.id } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.isPhone == true
                 ? "Anything waiting for it is discarded within 7 days. If the iPhone checks in again, it's added back."
                 : "You can add it again later with its Tailscale name.")
        }
        .onAppear(perform: takeTokenRequest)
        .onChange(of: settings.tokenRequest) { takeTokenRequest() }
        .sheet(item: $editing) { peer in
            PeerEditor(peer: peer, isNew: !settings.peers.contains { $0.id == peer.id }, focusToken: editingToken,
                       onRemove: { editing = nil; removing = peer }) { saved in
                if let saved, settings.save(saved) {
                    Task {
                        await settings.exchangeTokens(with: saved)
                        if let current = settings.peers.first(where: { $0.id == saved.id }) { await ping(current) }
                    }
                }
                editing = nil
            }
        }
    }

    private func ping(_ peer: Peer) async {
        pingResults[peer.id] = .checking
        pingResults[peer.id] = await settings.ping(peer)
    }
}

extension SettingsForm {
    private func editToken(_ peer: Peer) {
        editingToken = true
        editing = peer
    }

    /// Opens the device that a "Missing Token" button elsewhere asked for.
    private func takeTokenRequest() {
        guard let id = settings.tokenRequest, let peer = settings.peers.first(where: { $0.id == id }) else { return }
        settings.tokenRequest = nil
        editToken(peer)
    }
}

private struct PeerRow: View {
    var peer: Peer
    var result: PingResult?
    var onTest: () -> Void
    var onEdit: () -> Void
    var onRemove: () -> Void
    var onFixToken: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            GlyphCircle(symbol: Theme.symbol(for: peer), size: 34)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(peer.name).font(.body.weight(.medium))
                Text(peer.isPhone ? "iPhone · collects items when opened" : "\(peer.host):\(String(peer.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !peer.isPaired { MissingTokenButton(action: onFixToken) }
                statusLine
            }
            Spacer()
            if !peer.isPhone {
                Button("Test", action: onTest)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .accessibilityLabel("Edit \(peer.name)")
                .buttonStyle(.borderless)
        }
        .padding(.vertical, Space.xs)
    }

    @ViewBuilder private var statusLine: some View {
        if let result {
            switch result {
            case .checking:
                Label("Checking…", systemImage: "ellipsis").font(.caption2).foregroundStyle(.secondary)
            case .ok(let text):
                Label(text, systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

/// iPhone Settings › Appearance: the window style and the color theme.
struct AppearanceSettings: View {
    @Bindable var settings: DroprrSettings

    var body: some View {
        Form {
            Section {
                ColorModePicker(settings: settings)
            } header: {
                Text("Light or dark")
            } footer: {
                Text(Look.forcesDark ? "Spatial is always dark." : "System follows your iPhone.")
            }
            Section {
                StylePicker(settings: settings)
                    .listRowInsets(EdgeInsets(top: Space.md, leading: Space.md, bottom: Space.md, trailing: Space.md))
            } header: {
                Text("Style")
            }
            Section {
                ThemePicker(settings: settings)
                    .listRowInsets(EdgeInsets(top: Space.md, leading: Space.md, bottom: Space.md, trailing: Space.md))
            } header: {
                Text("Colors")
            } footer: {
                Text("Each theme has light and dark colors.")
            }
        }
        .scrollContentBackground(.hidden)
        .background { LookBackground().ignoresSafeArea() }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
