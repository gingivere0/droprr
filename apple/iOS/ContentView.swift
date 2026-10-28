import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PhoneModel
    @State private var scanning = false

    var body: some View {
        TabView {
            NavigationStack { SendTab(model: model) }
                .tabItem { Label("Send", systemImage: "paperplane.fill") }
            NavigationStack { ReceivedTab(model: model) }
                .tabItem { Label("Received", systemImage: "tray.and.arrow.down.fill") }
                .badge(model.newItems.count)
            NavigationStack {
                SettingsForm(settings: model.settings)
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { scanning = true } label: { Label("Scan Pairing Code", systemImage: "qrcode.viewfinder") }
                        }
                    }
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environment(\.startPairing, { scanning = true })
        .sheet(isPresented: $scanning) {
            PairingScannerSheet { model.pair(with: $0) }
        }
        .alert("Pairing", isPresented: Binding(
            get: { model.pairingMessage != nil && !scanning },
            set: { if !$0 { model.pairingMessage = nil } })) {
            Button("OK") { model.pairingMessage = nil }
        } message: {
            Text(model.pairingMessage ?? "")
        }
    }
}

private struct StartPairingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var startPairing: () -> Void {
        get { self[StartPairingKey.self] }
        set { self[StartPairingKey.self] = newValue }
    }
}

// MARK: - Send

private struct SendTab: View {
    @Bindable var model: PhoneModel
    @State private var peerID: UUID?
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var clipboard: SendPayload?
    @State private var files: [URL] = []
    @FocusState private var typing: Bool

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasStaged: Bool { clipboard != nil || !photos.isEmpty || !files.isEmpty || !trimmedText.isEmpty }

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
                    sendButton
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
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
                    .fontWeight(.semibold)
            }
        }
        .animation(.default, value: model.lastSendResult)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            withAnimation(.snappy) { files = urls.compactMap(Self.copyToTemp) }
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

    /// Tapping a card selects it; nothing goes out until Send. Tap a selected card's × to clear it.
    private var actionGrid: some View {
        HStack(spacing: 12) {
            ActionCard(title: "Clipboard", symbol: "doc.on.clipboard.fill",
                       detail: clipboard.map(\.label), selected: clipboard != nil,
                       onClear: { clipboard = nil }) {
                if clipboard != nil {
                    clipboard = nil
                } else if let payload = model.clipboardPayload() {
                    clipboard = payload
                } else {
                    model.lastSendResult = "The clipboard is empty."
                }
            }
            PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                ActionCardLabel(title: "Photos", symbol: "photo.fill.on.rectangle.fill",
                                detail: photos.isEmpty ? nil : "\(photos.count) selected", selected: !photos.isEmpty)
            }
            .buttonStyle(PressableStyle())
            .overlay(alignment: .topTrailing) {
                if !photos.isEmpty { ClearBadge { photos = [] } }
            }
            ActionCard(title: "Files", symbol: "folder.fill",
                       detail: files.isEmpty ? nil : "\(files.count) selected", selected: !files.isEmpty,
                       onClear: { files = [] }) {
                importing = true
            }
        }
        .disabled(model.sending)
        .animation(.snappy, value: hasStaged)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Text or link")
            TextField("Type or paste something", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .focused($typing)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var sendButton: some View {
        Button {
            guard let peer else { return }
            typing = false
            Task { await sendStaged(to: peer) }
        } label: {
            HStack(spacing: 8) {
                if model.sending { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") }
                Text(peer.map { "Send to \($0.name)" } ?? "Send")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.start.opacity(hasStaged ? 0.3 : 0), radius: 10, y: 5)
        }
        .buttonStyle(PressableStyle())
        .disabled(peer == nil || !hasStaged || model.sending)
        .opacity(hasStaged ? 1 : 0.45)
    }

    private func sendStaged(to peer: Peer) async {
        var payloads: [SendPayload] = []
        if !trimmedText.isEmpty {
            if let url = URL(string: trimmedText), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                payloads.append(.url(url))
            } else {
                payloads.append(.text(text))
            }
        }
        if let clipboard { payloads.append(clipboard) }
        var attachments = files
        if !photos.isEmpty {
            model.lastSendResult = "Preparing \(photos.count) photo\(photos.count == 1 ? "" : "s")…"
            attachments += await Self.export(photos)
        }
        if !attachments.isEmpty { payloads.append(.files(attachments)) }

        if await model.send(payloads, to: peer) {
            withAnimation(.snappy) {
                text = ""
                clipboard = nil
                photos = []
                files = []
            }
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
    var detail: String?
    var selected: Bool
    var onClear: () -> Void
    var action: () -> Void

    var body: some View {
        Button(action: action) { ActionCardLabel(title: title, symbol: symbol, detail: detail, selected: selected) }
            .buttonStyle(PressableStyle())
            .overlay(alignment: .topTrailing) {
                if selected { ClearBadge(action: onClear) }
            }
    }
}

private struct ActionCardLabel: View {
    var title: String
    var symbol: String
    var detail: String?
    var selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.gradient))
                    .frame(width: 46, height: 46)
                Image(systemName: selected ? "checkmark" : symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.start) : AnyShapeStyle(.white))
            }
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail ?? " ")
                .font(.caption2)
                .lineLimit(1)
                .opacity(detail == nil ? 0 : 0.9)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.regularMaterial))
        }
        .shadow(color: selected ? Theme.start.opacity(0.3) : .clear, radius: 8, y: 4)
    }
}

/// The small × on a selected card that unselects it.
private struct ClearBadge: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.start, .white)
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .accessibilityLabel("Clear")
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
    @Environment(\.startPairing) private var startPairing

    var body: some View {
        VStack(spacing: 14) {
            LogoBadge(size: 64)
            Text("Welcome to Droprr").font(.title2.weight(.bold))
            Text("On your PC or Mac, open Droprr and choose Pair a Phone. Then scan the code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: startPairing) {
                Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(Theme.gradient, in: Capsule())
            }
            .buttonStyle(PressableStyle())
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
    @State private var preview: URL?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    GlyphCircle(symbol: "arrow.down.circle", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.collecting ? "Checking your computers…" : (model.lastCollect ?? "Pull down to check"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Your PC and Mac hold items until this app opens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.collecting { ProgressView() }
                }
            }

            if model.history.isEmpty {
                Section {
                    ContentUnavailableView("Nothing yet", systemImage: "tray",
                                           description: Text("Things sent to this iPhone appear here."))
                }
            }

            if !model.newItems.isEmpty {
                Section {
                    ForEach(model.newItems) { row($0) }
                } header: {
                    HStack {
                        Text("New")
                        Spacer()
                        Button("Mark all as seen") { model.markAllSeen() }
                            .font(.caption)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Tap text or a link to copy it. Tap a file to open it.")
                }
            }

            if !model.seenItems.isEmpty {
                Section {
                    ForEach(model.seenItems) { row($0) }
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        Button("Clear") { model.clearHistory() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Received")
        .refreshable { await model.collectInbox() }
        .safeAreaInset(edge: .bottom) {
            Button(action: openReceivedFolder) {
                Label("Open received files in Files", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.start)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(item: Binding(get: { preview.map(PreviewFile.init) }, set: { preview = $0?.url })) { file in
            // A sheet instead of .quickLookPreview so photos and videos can be flicked down to close.
            QuickLookSheet(url: file.url)
                .ignoresSafeArea()
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.gradient, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let item = entry.item
        return Button {
            model.use(entry)
            switch item.kind {
            case .file(let url): preview = url
            case .text: show("Copied")
            case .url: show("Link copied")
            }
        } label: {
            HStack(spacing: 12) {
                GlyphCircle(symbol: Theme.symbol(for: item), size: 36, filled: entry.isNew)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body.weight(entry.isNew ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if entry.isNew {
                    Circle().fill(Theme.start).frame(width: 9, height: 9)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.delete(entry) } label: { Label("Remove", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            if entry.isNew {
                Button { model.markSeen(entry) } label: { Label("Seen", systemImage: "checkmark") }
                    .tint(Theme.start)
            }
        }
        .contextMenu {
            if case .url(let url) = item.kind {
                Link(destination: url) { Label("Open Link", systemImage: "safari") }
            }
            if case .file(let url) = item.kind {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { model.delete(entry) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func subtitle(_ entry: HistoryEntry) -> String {
        let kind = switch entry.type {
        case "file": "File"
        case "url": "Link"
        default: "Text"
        }
        let from = entry.source.map { " from \($0)" } ?? ""
        return "\(kind)\(from) · \(entry.date.formatted(.relative(presentation: .named)))"
    }

    /// Opens On My iPhone › Droprr › Received in the Files app.
    private func openReceivedFolder() {
        let folder = PhoneModel.inbox
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let url = URL(string: "shareddocuments://" + folder.path) else { return }
        UIApplication.shared.open(url)
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if toast == message { toast = nil }
        }
    }
}

private struct PreviewFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Quick Look inside a navigation bar (for Done and Share), shown in a swipe-to-dismiss sheet.
private struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        let close = dismiss
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in close() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
