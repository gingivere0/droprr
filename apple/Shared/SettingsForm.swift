import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PingResult { case checking, ok(String), failed(String) }

/// Token, device name, port and peers. Shared by the Mac Settings window and the iPhone Settings tab.
struct SettingsForm<Extra: View>: View {
    @Bindable var settings: DroprrSettings
    var extra: Extra
    @State private var editing: Peer?
    @State private var pingResults: [UUID: PingResult] = [:]
    @State private var showToken = false
    @State private var removing: Peer?

    init(settings: DroprrSettings, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.settings = settings
        self.extra = extra()
    }

    var body: some View {
        Form {
            Section {
                ForEach(settings.peers) { peer in
                    PeerRow(peer: peer, result: pingResults[peer.id],
                            onTest: { Task { await ping(peer) } },
                            onEdit: { editing = peer },
                            onRemove: { removing = peer })
                        .contextMenu {
                            Button("Edit…") { editing = peer }
                            Button("Remove \(peer.name)", role: .destructive) { removing = peer }
                        }
                }
                .onDelete { settings.peers.remove(atOffsets: $0) }
                Button {
                    editing = Peer(name: "", host: "")
                } label: {
                    Label("Add Device", systemImage: "plus.circle.fill")
                }
                #if os(macOS)
                .buttonStyle(HoverButtonStyle(.plain))
                #else
                .buttonStyle(.borderless)
                #endif
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
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    #if os(macOS)
                .buttonStyle(HoverButtonStyle(.plain))
                #else
                .buttonStyle(.borderless)
                #endif
                    #if os(macOS)
                    .hoverHint(showToken ? "Hide the token" : "Show the token")
                    #endif
                }
                HStack {
                    Button("Generate New") { settings.token = DroprrSettings.generateToken() }
                    Spacer()
                    Button("Copy") { Clipboard.copy(text: settings.token) }
                        .disabled(settings.token.isEmpty)
                }
                #if os(macOS)
                .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                #else
                .buttonStyle(.borderless)
                #endif
            } header: {
                Text("Pairing token")
            } footer: {
                Text("Use the same token on every device. It stays on this device.")
            }

            Section {
                TextField("Device name", text: $settings.deviceName)
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                extra
            } header: {
                Text("This device")
            } footer: {
                Text("Other devices see this name. Port \(String(DroprrDefaults.port)) is the default.")
            }
        }
        .formStyle(.grouped)
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
        .sheet(item: $editing) { peer in
            PeerEditor(peer: peer, isNew: !settings.peers.contains { $0.id == peer.id },
                       onRemove: { editing = nil; removing = peer }) { saved in
                if let saved {
                    if let i = settings.peers.firstIndex(where: { $0.id == saved.id }) {
                        settings.peers[i] = saved
                    } else {
                        settings.peers.append(saved)
                        Task { await ping(saved) }
                    }
                }
                editing = nil
            }
        }
    }

    private func ping(_ peer: Peer) async {
        pingResults[peer.id] = .checking
        do {
            let info = try await DroprrClient(peer: peer, token: settings.token).ping()
            pingResults[peer.id] = .ok("\(Theme.platformName(info.platform)) · v\(info.version)")
            if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                settings.peers[i].platform = info.platform
                settings.peers[i].remoteName = info.name
            }
        } catch {
            pingResults[peer.id] = .failed(peer.isPhone ? "Not reachable now (normal for an iPhone)" : error.localizedDescription)
        }
    }
}

private struct PeerRow: View {
    var peer: Peer
    var result: PingResult?
    var onTest: () -> Void
    var onEdit: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GlyphCircle(symbol: Theme.symbol(for: peer), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.body.weight(.medium))
                Text(peer.isPhone ? "iPhone · collects items when opened" : "\(peer.host):\(String(peer.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            Spacer()
            if !peer.isPhone {
                Button("Test", action: onTest)
                    #if os(macOS)
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                    #else
                    .buttonStyle(.bordered).controlSize(.small)
                    #endif
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                #if os(macOS)
                .buttonStyle(HoverButtonStyle(.plain))
                #else
                .buttonStyle(.borderless)
                #endif
                #if os(macOS)
                .hoverHint("Edit or rename this device")
                #endif
            #if os(macOS)
            Button(action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(.red)
                .hoverHint("Remove this device")
            #endif
        }
        .padding(.vertical, 2)
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

private struct PeerEditor: View {
    @State var peer: Peer
    var isNew: Bool
    var onRemove: () -> Void
    var done: (Peer?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $peer.name)
                    Toggle("This is an iPhone", isOn: $peer.isPhone)
                }
                if !peer.isPhone {
                    Section {
                        TextField("Tailscale name or address", text: $peer.host)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        TextField("Port", value: $peer.port, format: .number.grouping(.never))
                        SecureField("Its token (if different from yours)", text: Binding(
                            get: { peer.token ?? "" }, set: { peer.token = $0.isEmpty ? nil : $0 }))
                    } footer: {
                        Text("Find the name in the Tailscale app, for example my-pc. Scanning a device's pairing QR code fills all of this in.")
                    }
                } else {
                    Section {
                        Text("Items you send to an iPhone wait on this device until Droprr opens on the phone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !isNew {
                    Section {
                        Button("Remove Device", role: .destructive, action: onRemove)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Device" : peer.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if peer.name.isEmpty { peer.name = peer.host }
                        done(peer)
                    }
                    .disabled(peer.isPhone ? peer.name.isEmpty : peer.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}

enum Clipboard {
    static func copy(text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }
}
