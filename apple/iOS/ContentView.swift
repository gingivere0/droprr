import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PhoneModel

    var body: some View {
        TabView {
            NavigationStack { SendTab(model: model) }
                .tabItem { Label("Send", systemImage: "paperplane") }
            NavigationStack { ReceivedTab(model: model) }
                .tabItem { Label("Received", systemImage: "tray.and.arrow.down") }
            NavigationStack {
                SettingsForm(settings: model.settings).navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

private struct SendTab: View {
    @Bindable var model: PhoneModel
    @State private var peerID: UUID?
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false

    private var peer: Peer? {
        model.settings.peers.first { $0.id == peerID } ?? model.settings.lastPeer
    }

    var body: some View {
        Form {
            if model.settings.peers.isEmpty {
                Text("Add your PC or Mac in Settings, and set the same pairing token on every device.")
            } else {
                Picker("Send to", selection: Binding(get: { peer?.id }, set: { peerID = $0 })) {
                    ForEach(model.settings.peers) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            Section {
                Button {
                    guard let peer, let payload = model.clipboardPayload() else {
                        model.lastSendResult = "The clipboard is empty."
                        return
                    }
                    Task { await model.send(payload, to: peer) }
                } label: {
                    Label("Send Clipboard", systemImage: "doc.on.clipboard")
                }
                PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                    Label("Send Photos or Videos", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: {
                    Label("Send Files", systemImage: "folder")
                }
            }
            .disabled(peer == nil || model.sending)

            Section("Text or link") {
                TextField("Type or paste", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                Button("Send Text") {
                    guard let peer else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload: SendPayload
                    if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                        payload = .url(url)
                    } else {
                        payload = .text(text)
                    }
                    Task {
                        await model.send(payload, to: peer)
                        text = ""
                    }
                }
                .disabled(peer == nil || text.isEmpty || model.sending)
            }

            if let result = model.lastSendResult {
                Section { Text(result).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Droprr")
        .onChange(of: photos) { _, items in
            guard !items.isEmpty, let peer else { return }
            photos = []
            Task {
                let files = await Self.export(items)
                await model.send(.files(files), to: peer)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let peer, case .success(let urls) = result else { return }
            let files = urls.compactMap(Self.copyToTemp)
            Task { await model.send(.files(files), to: peer) }
        }
    }

    private static func export(_ items: [PhotosPickerItem]) async -> [URL] {
        var files: [URL] = []
        for (i, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Photo \(i + 1)-\(UUID().uuidString.prefix(4)).\(ext)")
            if (try? data.write(to: file)) != nil { files.append(file) }
        }
        return files
    }

    private static func copyToTemp(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }
}

private struct ReceivedTab: View {
    @Bindable var model: PhoneModel

    var body: some View {
        List {
            Section {
                Text(model.status)
            } footer: {
                Text("iPhone receives only while Droprr is open. Files are saved in Files › On My iPhone › Droprr › Received.")
            }
            ForEach(model.received) { item in
                switch item.kind {
                case .file(let url):
                    ShareLink(item: url) { Label(item.title, systemImage: "doc") }
                case .url(let url):
                    Link(destination: url) { Label(item.title, systemImage: "link") }
                case .text(let text):
                    Button { Clipboard.copy(text: text) } label: { Label(item.title, systemImage: "text.alignleft") }
                }
            }
        }
        .navigationTitle("Received")
    }
}
