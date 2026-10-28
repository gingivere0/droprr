import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PhoneModel
    @State private var scanning = false
    /// Debug builds accept `-DroprrTab 0|1|2` to open a tab (for screenshots).
    @State private var tab: Int = {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "DroprrTab")
        #else
        return 0
        #endif
    }()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { SendTab(model: model) }
                .tabItem { Label("Send", systemImage: "paperplane.fill") }
                .tag(0)
            NavigationStack { ReceivedTab(model: model) }
                .tag(1)
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
            .tag(2)
        }
        .tint(Theme.accentText)
        // The home-screen icon follows the theme too (alternate app icons).
        .onAppear { AppIconSwitcher.apply(model.settings.theme) }
        .onChange(of: model.settings.theme) { _, theme in AppIconSwitcher.apply(theme) }
        .environment(\.startPairing, { scanning = true })
        .environment(\.pairWithCode, { model.pair(with: $0) })
        .sheet(isPresented: $scanning) {
            PairingScannerSheet { model.pair(with: $0) }
        }
        .sheet(isPresented: Binding(get: { model.pendingPairing != nil }, set: { if !$0 { model.pendingPairing = nil } })) {
            if let info = model.pendingPairing {
                ConfirmPairingSheet(info: info, replacing: model.existingPeer(for: info),
                                    onPair: { model.completePairing(info) },
                                    onCancel: { model.pendingPairing = nil })
                    .presentationDetents([.medium])
            }
        }
        .overlay {
            if let status = model.pairingStatus, !scanning {
                PairingStatusCard(status: status) { model.pairingStatus = nil }
            }
        }
        .motion(Motion.slow, value: model.pairingStatus)
    }
}

/// Shown when a pairing link is opened from outside the app: nothing changes until Pair is tapped.
private struct ConfirmPairingSheet: View {
    var info: PairingInfo
    var replacing: Peer?
    var onPair: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Space.md) {
                        GlyphCircle(symbol: info.platform == "macos" ? "laptopcomputer" : "pc", size: 44, filled: true)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(info.name).font(.headline)
                            Text(Theme.platformName(info.platform)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Address", value: "\(info.connectHost):\(String(info.port))")
                        .font(.callout.monospaced())
                } footer: {
                    if let replacing {
                        Text("This replaces the address and token saved for \(replacing.name).")
                    } else {
                        Text("Only pair with your own computers.")
                    }
                }
            }
            .navigationTitle("Pair with \(info.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Pair", action: onPair).fontWeight(.semibold) }
            }
        }
    }
}

/// Pairing progress, then a clear result: success fades away on its own, failure waits for OK.
private struct PairingStatusCard: View {
    var status: PhoneModel.PairingStatus
    var dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: Space.lg) {
                switch status {
                case .working(let text):
                    ProgressView().controlSize(.large)
                    Text(text).font(.headline).multilineTextAlignment(.center)
                case .success(let text):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.start)
                    Text(text).font(.headline).multilineTextAlignment(.center)
                    Text("You can send to it now.").font(.subheadline).foregroundStyle(.secondary)
                case .failure(let text):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(text).font(.subheadline).multilineTextAlignment(.center)
                    Button("OK", action: dismiss)
                        .font(.headline)
                        .padding(.horizontal, Space.xxl)
                        .padding(.vertical, Space.md)
                        .foregroundStyle(Theme.onPrimaryButton)
                        .background(Theme.primaryButton, in: Capsule())
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: 300)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .shadow(radius: 20)
        }
        .transition(.opacity)
        .onTapGesture { if case .success = status { dismiss() } }
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
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                if desktops.isEmpty {
                    EmptyDevicesCard()
                } else {
                    devicePicker
                    actionGrid
                    composer
                    SendStatusView(message: model.lastSendResult, progress: model.progress)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        // The Send button stays pinned above the tab bar so it's always in reach.
        .safeAreaInset(edge: .bottom) {
            if !desktops.isEmpty {
                sendButton
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .background(.bar)
            }
        }
        .sensoryFeedback(.selection, trigger: peerID)
        .background(backdrop)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
                    .fontWeight(.semibold)
            }
        }
        .motion(Motion.standard, value: model.lastSendResult)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Motion.perform { files = urls.compactMap(Self.copyToTemp) }
        }
    }

    private var backdrop: some View {
        // The gradient is for small surfaces only; screens use the system background.
        Theme.surface.ignoresSafeArea()
    }

    /// Logo, a large "Send" title and who it's going to, like the Mac's Send window.
    private var header: some View {
        HStack(spacing: Space.md) {
            LogoBadge(size: 44).id(model.settings.theme)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send").font(.largeTitle.weight(.bold))
                Text(peer.map { "To \($0.name)" } ?? "Pair a computer to start")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Device tiles like the Mac's: the selected one fills with the theme color.
    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionLabel("Send to")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)],
                      spacing: Space.md) {
                ForEach(desktops) { device in
                    let selected = device.id == peer?.id
                    Button {
                        Motion.perform { peerID = device.id }
                    } label: {
                        HStack(spacing: Space.md) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Theme.onAccent.opacity(0.18) : Theme.accentTint)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    Image(systemName: selected ? "checkmark" : Theme.symbol(for: device))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(selected ? Theme.onAccent : Theme.accentText)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.subheadline.weight(.semibold))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                Text(Theme.platformName(device.platform)).font(.caption)
                                    .foregroundStyle(selected ? Theme.onAccent.opacity(0.75) : Color.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selected ? Theme.onAccent : Color.primary)
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selected ? Theme.start : Theme.tile)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(selected ? .clear : Theme.stroke, lineWidth: 1))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(device.name), \(Theme.platformName(device.platform))")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    /// Tapping a card selects it; nothing goes out until Send. Tap a selected card's × to clear it.
    /// Bento: Photos is the tall tile; Clipboard and Files stack beside it.
    private var actionGrid: some View {
        HStack(alignment: .top, spacing: Space.md) {
            PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos])) {
                ActionCardLabel(title: "Photos", symbol: "photo.fill.on.rectangle.fill",
                                detail: photos.isEmpty ? "Pick photos or videos" : "\(photos.count) selected", selected: !photos.isEmpty)
            }
            .buttonStyle(PressableStyle())
            .frame(height: 240)
            .overlay(alignment: .topTrailing) {
                if !photos.isEmpty { ClearBadge { photos = [] } }
            }
            VStack(spacing: Space.md) {
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
                .frame(height: 114)
                ActionCard(title: "Files", symbol: "folder.fill",
                           detail: files.isEmpty ? nil : "\(files.count) selected", selected: !files.isEmpty,
                           onClear: { files = [] }) {
                    importing = true
                }
                .frame(height: 114)
            }
        }
        .frame(height: 240)
        .disabled(model.sending)
        .motion(Motion.standard, value: hasStaged)
    }

    /// The theme's secondary-colored tile, like the Mac's message tile.
    private var composer: some View {
        HStack(alignment: .top, spacing: Space.md) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.secondaryText)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.tile)
                }
                .accessibilityHidden(true)
            TextField("Add a message or paste a link", text: $text, axis: .vertical)
                .lineLimit(2...8)
                .focused($typing)
                .padding(.top, 6)
        }
        .padding(Space.lg)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(Theme.secondaryTint)
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(typing ? Theme.secondaryText : .clear, lineWidth: 2))
        }
        .motion(Motion.fast, value: typing)
    }

    private var sendButton: some View {
        Button {
            guard let peer else { return }
            typing = false
            Task { await sendStaged(to: peer) }
        } label: {
            HStack(spacing: Space.sm) {
                if model.sending { ProgressView().tint(Theme.onPrimaryButton) } else { Image(systemName: "paperplane.fill") }
                Text(peer.map { "Send to \($0.name)" } ?? "Send")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.lg)
            .foregroundStyle(Theme.onPrimaryButton)
            .background(Theme.primaryButton, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
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
            Motion.perform {
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
        VStack(spacing: Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Theme.onAccent.opacity(0.18) : Theme.accentTint)
                    .frame(width: 46, height: 46)
                Image(systemName: selected ? "checkmark" : symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Theme.onAccent : Theme.accentText)
            }
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail ?? " ")
                .font(.caption2)
                .lineLimit(1)
                .opacity(detail == nil ? 0 : 0.9)
        }
        .foregroundStyle(selected ? Theme.onAccent : .primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Space.lg)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(selected ? Theme.start : Theme.tile)
                .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(selected ? .clear : Theme.stroke, lineWidth: 1))
        }
    }
}

/// The small × on a selected card that unselects it.
private struct ClearBadge: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.primaryButton, Theme.onPrimaryButton)
                .frame(width: 44, height: 44)   // 44 pt tap target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: Space.md, y: -Space.md)
        .accessibilityLabel("Clear")
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .motion(Motion.fast, value: configuration.isPressed)
    }
}

private struct EmptyDevicesCard: View {
    @Environment(\.startPairing) private var startPairing

    var body: some View {
        VStack(spacing: Space.lg) {
            LogoBadge(size: 64)
            Text("Welcome to Droprr").font(.title2.weight(.bold))
            Text("On your PC or Mac, open Droprr and choose Pair a Phone. Then scan the code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: startPairing) {
                Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.md)
                    .foregroundStyle(Theme.onPrimaryButton)
                    .background(Theme.primaryButton, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xxl)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .padding(.top, Space.xxl)
    }
}

// MARK: - Received

private struct ReceivedTab: View {
    @Bindable var model: PhoneModel
    @Environment(\.openURL) private var openURL
    @State private var preview: URL?
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: Space.md) {
                    GlyphCircle(symbol: "arrow.down.circle", size: 36)
                    VStack(alignment: .leading, spacing: Space.xs) {
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
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .refreshable { await model.collectInbox() }
        .safeAreaInset(edge: .bottom) {
            Button(action: openReceivedFolder) {
                Label("Open received files in Files", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.md)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(Theme.surface)   // a solid band, so list rows don't show through
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
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(Theme.gradient, in: Capsule())
                    .padding(.bottom, Space.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motion(Motion.slow, value: toast)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let item = entry.item
        // Like Chrome's downloads: tap the row to open; buttons copy, show in Files, or remove from the list.
        return HStack(spacing: Space.xs) {
            Button {
                model.use(entry)
                switch item.kind {
                case .file(let url): preview = url
                case .text: show("Copied")
                case .url: show("Link copied")
                }
            } label: {
                HStack(spacing: Space.md) {
                    GlyphCircle(symbol: Theme.symbol(for: item), size: 36)
                        .overlay(alignment: .topTrailing) {
                            if entry.isNew {
                                Circle().fill(Theme.start)
                                    .overlay(Circle().strokeBorder(Theme.tile, lineWidth: 2))
                                    .frame(width: 12, height: 12)
                                    .offset(x: 4, y: -4)
                                    .accessibilityLabel("New")
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body.weight(entry.isNew ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(subtitle(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)

            RowIconButton(symbol: "doc.on.doc", label: "Copy") {
                Clipboard.copy(item)
                model.markSeen(entry)
                show("Copied")
            }
            if case .file = item.kind {
                RowIconButton(symbol: "folder", label: "Show in Files") { openReceivedFolder() }
            }
            RowIconButton(symbol: "xmark", label: "Remove from list") { model.delete(entry) }
        }
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
            if case .url(let url) = item.kind, Links.isWeb(url) {
                Button { openURL(url) } label: { Label("Open Link", systemImage: "safari") }
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
        // "Type · time", like the Mac and PC lists; the sender shows in the context menu.
        return "\(kind) · \(entry.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
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

/// Switches the home-screen icon to the theme's recolored logo. Graphite & Lime uses the main icon.
enum AppIconSwitcher {
    @MainActor
    static func apply(_ theme: String) {
        let wanted: String? = theme == ThemePalette.defaultID ? nil : "AppIcon-\(theme)"
        guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != wanted else { return }
        UIApplication.shared.setAlternateIconName(wanted) { _ in }
    }
}

/// A small icon button in a Received row with a 44-pt tap target.
private struct RowIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
