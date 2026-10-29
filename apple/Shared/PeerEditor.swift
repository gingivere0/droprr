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
            // Answered over Tailscale, which already authenticates the device: pin it if it's new (protocol 2).
            learn(peer.id, deviceID: info.id, fingerprint: info.fp, tlsPort: info.tlsPort, lan: nil)
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
                if isNew { NearbySection { done(nil) } }
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

/// Add Device › Nearby: Droprr devices on this Wi-Fi that aren't paired yet. Picking one asks it to
/// pair; both screens show the same six digits and the other device's person confirms.
private struct NearbySection: View {
    var onPaired: () -> Void
    @State private var discovery = LANDiscovery.shared
    @State private var pairing: String?
    @State private var code: String?
    @State private var failure: String?
    private var settings: DroprrSettings { .shared }

    private var unpaired: [NearbyDevice] {
        discovery.nearby.filter { device in
            !settings.peers.contains { $0.deviceID == device.id && $0.fingerprint == device.fingerprint && $0.isPaired }
        }
    }

    var body: some View {
        if settings.localNetwork {
            Section {
                if unpaired.isEmpty {
                    Label("Looking for devices on this Wi-Fi…", systemImage: "wifi")
                        .foregroundStyle(.secondary)
                }
                ForEach(unpaired) { device in
                    Button { start(device) } label: {
                        HStack {
                            Image(systemName: device.platform == "ios" ? "iphone" : device.platform == "windows" ? "pc" : "laptopcomputer")
                                .frame(width: 24)
                            Text(device.name)
                            Spacer()
                            if pairing == device.id {
                                if let code {
                                    Text(code).font(.body.monospacedDigit().weight(.semibold))
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pairing != nil)
                }
            } header: {
                Text("Nearby")
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.orange)
                } else if let code, let name = discovery.nearby.first(where: { $0.id == pairing })?.name {
                    Text("Make sure \(name) shows \(code), then confirm there.")
                } else {
                    Text("Devices with Droprr open on this Wi-Fi. Pick one to pair; you'll confirm a code on it.")
                }
            }
            .onAppear { discovery.start() }
        }
    }

    private func start(_ device: NearbyDevice) {
        pairing = device.id
        code = nil
        failure = nil
        Task {
            do {
                _ = try await LANPairing.pair(with: device) { code = $0 }
                onPaired()
            } catch {
                failure = "Couldn't pair with \(device.name): \(error.localizedDescription)"
            }
            pairing = nil
            code = nil
        }
    }
}
