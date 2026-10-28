import SwiftUI
import UniformTypeIdentifiers
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
            #if os(iOS)
            Section {
                StylePicker(settings: settings)
                    .listRowInsets(EdgeInsets(top: Space.md, leading: Space.md, bottom: Space.md, trailing: Space.md))
            } header: {
                Text("Style")
            } footer: {
                Text("Spatial is always dark.")
            }
            Section {
                ThemePicker(settings: settings)
                    .listRowInsets(EdgeInsets(top: Space.md, leading: Space.md, bottom: Space.md, trailing: Space.md))
            } header: {
                Text("Colors")
            } footer: {
                Text("Light and dark follow your iPhone.")
            }
            #endif
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
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
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
                #if os(macOS)
                Text("This Mac's token")
                #else
                Text("Default token")
                #endif
            } footer: {
                #if os(macOS)
                Text("Devices need this token to send to this Mac. A phone gets it by scanning the Pair a Phone code.")
                #else
                Text("Used only for devices you add by hand. Devices paired with a QR code keep their own token.")
                #endif
            }

            Section {
                TextField("Device name", text: $settings.deviceName)
                #if os(macOS)
                Toggle("Auto-copy received items to clipboard", isOn: $settings.autoCopy)
                    .hoverHint("Copies everything as it arrives, including files and images.")
                #else
                Toggle("Auto-copy received items to clipboard", isOn: $settings.autoCopy)
                #endif
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
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background { LookBackground().ignoresSafeArea() }
        #endif
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
                    let tokenChanged = settings.peers.first { $0.id == saved.id }?.token != saved.token
                    if let i = settings.peers.firstIndex(where: { $0.id == saved.id }) {
                        settings.peers[i] = saved
                    } else {
                        settings.peers.append(saved)
                    }
                    if tokenChanged {
                        Task {
                            await settings.exchangeTokens(with: saved)
                            if let current = settings.peers.first(where: { $0.id == saved.id }) { await ping(current) }
                        }
                    }
                }
                editing = nil
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
        HStack(spacing: Space.md) {
            GlyphCircle(symbol: Theme.symbol(for: peer), size: 34)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(peer.name).font(.body.weight(.medium))
                Text(peer.isPhone ? "iPhone · collects items when opened" : "\(peer.host):\(String(peer.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !peer.isPaired {
                    Label("Not paired: scan its code or enter its token", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
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
                .accessibilityLabel("Edit \(peer.name)")
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
                .accessibilityLabel("Remove \(peer.name)")
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(.red)
                .hoverHint("Remove this device")
            #endif
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

struct PeerEditor: View {
    @State var peer: Peer
    var isNew: Bool
    var onRemove: () -> Void
    var done: (Peer?) -> Void
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
                        SecureField("Its token", text: Binding(
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

enum Clipboard {
    /// Copies a received item: text, a web link (other schemes as text), an image as image data,
    /// or another file as a file. Marked concealed so clipboard managers don't keep a history of it.
    static func copy(_ item: ReceivedItem) {
        switch item.kind {
        case .text(let text): copy(text: text, concealed: true)
        case .url(let url): copy(url: url, concealed: true)
        case .file(let file): copy(file: file, concealed: true)
        }
    }

    static func copy(file: URL, concealed: Bool = false) {
        let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = []
        if isImage, let image = NSImage(contentsOf: file) { objects.append(image) }
        objects.append(file as NSURL)
        pb.writeObjects(objects)
        if concealed { conceal(pb) }
        #else
        if isImage, let image = UIImage(contentsOfFile: file.path) {
            UIPasteboard.general.image = image
        } else if let type = UTType(filenameExtension: file.pathExtension), let data = try? Data(contentsOf: file) {
            UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        }
        #endif
    }

    static func copy(text: String, concealed: Bool = false) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed { conceal(pb) }
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(url: URL, concealed: Bool = false) {
        guard Links.isWeb(url) else { return copy(text: url.absoluteString, concealed: concealed) }
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setString(url.absoluteString, forType: .string)
        if concealed { conceal(pb) }
        #else
        UIPasteboard.general.url = url
        #endif
    }

    #if os(macOS)
    /// nspasteboard.org convention: clipboard managers skip items marked concealed.
    private static func conceal(_ pb: NSPasteboard) {
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
    #endif
}
