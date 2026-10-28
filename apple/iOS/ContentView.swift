import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PhoneModel

    var body: some View {
        TabView {
            NavigationStack { SendTab(model: model) }
                .tabItem { Label("Send", systemImage: "paperplane.fill") }
            NavigationStack { ReceivedTab(model: model) }
                .tabItem { Label("Received", systemImage: "tray.and.arrow.down.fill") }
                .badge(model.received.count)
            NavigationStack {
                SettingsForm(settings: model.settings).navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

// MARK: - Send

private struct SendTab: View {
    @Bindable var model: PhoneModel
    @State private var peerID: UUID?
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @FocusState private var typing: Bool

    private var desktops: [Peer] { model.settings.peers.filter { !$0.isPhone } }
    private var peer: Peer? {
        desktops.first { $0.id == peerID } ?? desktops.first { $0.id == model.settings.lastPeerID } ?? desktops.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if desktops.isEmpty {
                    EmptyDevicesCard()
                } else {
                    devicePicker
                    actionGrid
                    composer
                    SendStatusView(message: model.lastSendResult, progress: model.progress)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(backdrop)
        .navigationTitle("Droprr")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LogoBadge(size: 28) }
        }
        .animation(.default, value: model.lastSendResult)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty, let peer else { return }
            photos = []
            Task {
                model.lastSendResult = "Preparing \(items.count) item\(items.count == 1 ? "" : "s")…"
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

    private var backdrop: some View {
        Theme.gradient
            .opacity(0.10)
            .ignoresSafeArea()
            .background(Color(.systemGroupedBackground))
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Send to")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(desktops) { device in
                        let selected = device.id == peer?.id
                        Button {
                            withAnimation(.snappy) { peerID = device.id }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: Theme.symbol(for: device))
                                Text(device.name).fontWeight(.semibold)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background {
                                Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.regularMaterial))
                            }
                            .shadow(color: selected ? Theme.start.opacity(0.3) : .clear, radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var actionGrid: some View {
        HStack(spacing: 12) {
            ActionCard(title: "Clipboard", symbol: "doc.on.clipboard.fill") {
                guard let peer else { return }
                guard let payload = model.clipboardPayload() else {
                    model.lastSendResult = "The clipboard is empty."
                    return
                }
                Task { await model.send(payload, to: peer) }
            }
            PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                ActionCardLabel(title: "Photos", symbol: "photo.fill.on.rectangle.fill")
            }
            .buttonStyle(PressableStyle())
            ActionCard(title: "Files", symbol: "folder.fill") { importing = true }
        }
        .disabled(peer == nil || model.sending)
        .opacity(model.sending ? 0.6 : 1)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Text or link")
            VStack(alignment: .trailing, spacing: 10) {
                TextField("Type or paste something", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($typing)
                Button {
                    guard let peer else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload: SendPayload
                    if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                        payload = .url(url)
                    } else {
                        payload = .text(text)
                    }
                    typing = false
                    Task {
                        await model.send(payload, to: peer)
                        text = ""
                    }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(peer == nil || text.isEmpty || model.sending)
                .opacity(text.isEmpty ? 0.5 : 1)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

private struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

private struct ActionCard: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { ActionCardLabel(title: title, symbol: symbol) }
            .buttonStyle(PressableStyle())
    }
}

private struct ActionCardLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        VStack(spacing: 10) {
            GlyphCircle(symbol: symbol, size: 46, filled: true)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

private struct EmptyDevicesCard: View {
    var body: some View {
        VStack(spacing: 14) {
            LogoBadge(size: 64)
            Text("Welcome to Droprr").font(.title2.weight(.bold))
            Text("Open Settings, paste the pairing token from your PC or Mac, and add each computer by its Tailscale name.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 40)
    }
}

// MARK: - Received

private struct ReceivedTab: View {
    @Bindable var model: PhoneModel

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    GlyphCircle(symbol: model.isListening ? "antenna.radiowaves.left.and.right" : "moon.zzz.fill",
                                size: 36, filled: model.isListening)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isListening ? "Receiving while open" : "Not receiving").font(.body.weight(.medium))
                        Text(model.collecting ? "Checking your computers…" : (model.lastCollect ?? "Pull down to check your computers"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.collecting { ProgressView() }
                }
            } footer: {
                Text("Files are saved in Files › On My iPhone › Droprr › Received. Text and links are copied.")
            }

            if model.received.isEmpty {
                Section {
                    ContentUnavailableView("Nothing yet", systemImage: "tray",
                                           description: Text("Things sent to this iPhone appear here."))
                }
            } else {
                Section("Recent") {
                    ForEach(model.received) { item in
                        row(item)
                    }
                }
            }
        }
        .navigationTitle("Received")
        .refreshable { await model.collectInbox() }
    }

    @ViewBuilder private func row(_ item: ReceivedItem) -> some View {
        let label = HStack(spacing: 12) {
            GlyphCircle(symbol: Theme.symbol(for: item), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(2).foregroundStyle(.primary)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        switch item.kind {
        case .file(let url): ShareLink(item: url) { label }
        case .url(let url): Link(destination: url) { label }
        case .text(let text): Button { Clipboard.copy(text: text) } label: { label }
        }
    }
}
