import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Token, device name, port and peers. Shared by the Mac Settings window and the iPhone Settings tab.
struct SettingsForm: View {
    @Bindable var settings: DroprrSettings
    @State private var editing: Peer?
    @State private var pingResults: [UUID: String] = [:]
    @State private var showToken = false

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $settings.deviceName)
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
            } header: {
                Text("This device")
            } footer: {
                Text("Other devices send to this port. Default \(String(DroprrDefaults.port)).")
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
                    Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        .buttonStyle(.borderless)
                }
                HStack {
                    Button("Generate new token") { settings.token = DroprrSettings.generateToken() }
                    Spacer()
                    Button("Copy") { Clipboard.copy(text: settings.token) }
                        .disabled(settings.token.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Pairing token")
            } footer: {
                Text("Use the same token on every device. It stays on this device and is never synced.")
            }

            Section {
                ForEach(settings.peers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text("\(peer.host):\(String(peer.port))").font(.caption).foregroundStyle(.secondary)
                            if let result = pingResults[peer.id] {
                                Text(result).font(.caption)
                            }
                        }
                        Spacer()
                        Button("Test") { Task { await ping(peer) } }
                            .buttonStyle(.borderless)
                        Button("Edit") { editing = peer }
                            .buttonStyle(.borderless)
                    }
                }
                .onDelete { settings.peers.remove(atOffsets: $0) }
                Button("Add device…") { editing = Peer(name: "", host: "") }
                    .buttonStyle(.borderless)
            } header: {
                Text("Devices")
            } footer: {
                Text("Use each device's Tailscale name (e.g. my-pc) or its 100.x address.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { peer in
            PeerEditor(peer: peer) { saved in
                if let saved {
                    if let i = settings.peers.firstIndex(where: { $0.id == saved.id }) {
                        settings.peers[i] = saved
                    } else {
                        settings.peers.append(saved)
                    }
                }
                editing = nil
            }
        }
    }

    private func ping(_ peer: Peer) async {
        pingResults[peer.id] = "Checking…"
        do {
            let info = try await DroprrClient(peer: peer, token: settings.token).ping()
            pingResults[peer.id] = "✓ \(info.name) (\(info.platform) \(info.version))"
        } catch {
            pingResults[peer.id] = "✗ \(error.localizedDescription)"
        }
    }
}

private struct PeerEditor: View {
    @State var peer: Peer
    var done: (Peer?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $peer.name)
                TextField("Tailscale name or address", text: $peer.host)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Port", value: $peer.port, format: .number.grouping(.never))
            }
            .formStyle(.grouped)
            .navigationTitle(peer.name.isEmpty ? "New device" : peer.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if peer.name.isEmpty { peer.name = peer.host }
                        done(peer)
                    }
                    .disabled(peer.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
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
