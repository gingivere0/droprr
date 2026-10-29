import SwiftUI

enum PingResult { case checking, ok(String), failed(String) }

extension DroprrSettings {
    /// Saves an edited or new device. Returns true when its token changed, so the caller can
    /// switch both sides to per-device tokens and check the connection.
    func save(_ peer: Peer) -> Bool {
        let tokenChanged = peers.first { $0.id == peer.id }?.token != peer.token
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[i] = peer
        } else {
            peers.append(peer)
        }
        return tokenChanged
    }

    /// Checks that a device answers, and remembers what it says it is.
    func ping(_ peer: Peer) async -> PingResult {
        do {
            let info = try await DroprrClient(peer: peer).ping()
            if let i = peers.firstIndex(where: { $0.id == peer.id }) {
                peers[i].platform = info.platform
                peers[i].remoteName = info.name
            }
            return .ok("\(Theme.platformName(info.platform)) · v\(info.version)")
        } catch {
            return .failed(peer.isPhone ? "Not reachable now (normal for an iPhone)" : error.localizedDescription)
        }
    }
}

/// "Missing Token" on a device that can't be sent to yet; clicking it opens that device's token.
struct MissingTokenButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Missing Token", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .hoverHint("Enter this device's token")
        #endif
    }
}

struct PeerEditor: View {
    @State var peer: Peer
    var isNew: Bool
    /// Open with the token field focused (from "Missing Token").
    var focusToken = false
    var onRemove: () -> Void
    var done: (Peer?) -> Void
    enum Field { case name, token }
    @FocusState private var focused: Field?
    @State private var showToken = false
    #if os(iOS)
    @Environment(\.pairWithCode) private var pairWithCode
    @State private var scanning = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                if isNew {
                    Section {
                        Button { scanning = true } label: {
                            Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                                .font(.body.weight(.semibold))
                        }
                    } footer: {
                        Text("On the computer, open Droprr and choose Pair a Phone. Or fill in the details below.")
                    }
                }
                #endif
                #if os(macOS)
                if isNew {
                    Section {
                        HStack {
                            Spacer()
                            PairingQRCode(settings: DroprrSettings.shared, size: 170)
                            Spacer()
                        }
                        .padding(.vertical, Space.sm)
                    } header: {
                        Text("Pair a phone")
                    } footer: {
                        Text("Scan this with the Camera app or Droprr on your iPhone. It adds itself here. To add a computer, fill in its details below.")
                    }
                }
                #endif
                Section {
                    TextField("Name", text: $peer.name)
                        .focused($focused, equals: .name)
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
                        HStack {
                            let token = Binding(get: { peer.token ?? "" }, set: { peer.token = $0.isEmpty ? nil : $0 })
                            Group {
                                if showToken { TextField("Its token", text: token) } else { SecureField("Its token", text: token) }
                            }
                            .focused($focused, equals: .token)
                            Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(showToken ? "Hide token" : "Show token")
                        }
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
            .onAppear {
                // Add Device starts in the name field; "Missing Token" starts in the token field.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    focused = focusToken && !peer.isPhone ? .token : (isNew ? .name : nil)
                }
            }
            #if os(macOS)
            // A phone that scans the code adds itself, so this screen's job is done.
            .onChange(of: DroprrSettings.shared.peers.count) { old, new in
                if isNew && new > old { done(nil) }
            }
            #endif
            #if os(iOS)
            .sheet(isPresented: $scanning) {
                PairingScannerSheet { code in
                    done(nil)
                    // Let this screen close before the pairing result is shown.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pairWithCode(code) }
                }
            }
            #endif
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
