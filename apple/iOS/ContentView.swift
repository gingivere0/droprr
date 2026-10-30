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
                    .scrollContentBackground(.hidden)
                    .background { LookBackground().ignoresSafeArea() }
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
        .tint(Look.accentText)
        .foregroundStyle(Look.ink)
        .fontDesign(Look.style == .clay ? .rounded : nil)
        .preferredColorScheme(Look.colorScheme)
        // The home-screen icon follows the theme too (alternate app icons).
        .onAppear { AppIconSwitcher.apply(model.settings.theme) }
        // Every screen's titles use the style's font, like the Send screen.
        .onAppear { Look.applyNavigationFonts() }
        .onChange(of: model.settings.style) { Look.applyNavigationFonts() }
        .onChange(of: model.settings.theme) { _, theme in AppIconSwitcher.apply(theme) }
        // "Missing Token" on the Send tab opens that device in Settings.
        .onChange(of: model.settings.localNetwork) { _, on in if on { model.startLocalNetwork() } else { model.stopLocalNetwork() } }
        .onChange(of: model.settings.tokenRequest) { _, id in if id != nil { tab = 2 } }
        .onChange(of: model.justAdded) { _, id in if id != nil { tab = 0 } }
        // A finished send's line doesn't follow you to another tab.
        .onChange(of: tab) { if !model.sending { model.lastSendResult = nil } }
        .environment(\.startPairing, { scanning = true })
        .environment(\.pairWithCode, { model.pair(with: $0) })
        .sheet(isPresented: $scanning) {
            PairingScannerSheet { model.pair(with: $0) }
        }
        // A computer on this Wi-Fi asking to pair (POST /pair/request): confirm with the shared code.
        .alert("Pair with \(model.pairQuestion?.name ?? "this device")?",
               isPresented: Binding(get: { model.pairQuestion != nil }, set: { if !$0 && model.pairQuestion != nil { model.answerPairQuestion(false) } })) {
            Button("Pair") { model.answerPairQuestion(true) }
            Button("Decline", role: .cancel) { model.answerPairQuestion(false) }
        } message: {
            Text("Make sure \(model.pairQuestion?.name ?? "it") shows \(model.pairQuestion?.code ?? "").")
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
                        GlyphCircle(symbol: info.isBrowser ? "globe" : info.platform == "macos" ? "laptopcomputer" : "pc", size: 44, filled: true)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(info.name).font(.headline)
                            Text(Theme.platformName(info.platform)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if !info.isBrowser {
                        LabeledContent("Address", value: "\(info.connectHost):\(String(info.port))")
                            .font(.callout.monospaced())
                    }
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
            .background { LookTile(selected: false) }
            .shadow(radius: 20)
        }
        .transition(.opacity)
        .onTapGesture { if case .success = status { dismiss() } }
    }
}

// MARK: - Send

private struct SendTab: View {
    @Bindable var model: PhoneModel
    @Environment(\.startPairing) private var startPairing
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
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                if desktops.isEmpty {
                    EmptyDevicesCard()
                } else {
                    devicePicker
                    actionGrid
                    composer.id("composer")
                    SendStatusView(message: model.lastSendResult, progress: model.progress, onCancel: model.cancelSend,
                               onDismiss: { model.lastSendResult = nil })
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.lg)
            // Tapping outside the text box ends editing (as does scrolling); buttons still get their taps.
            .contentShape(Rectangle())
            .onTapGesture { typing = false }
        }
        .scrollDismissesKeyboard(.interactively)
        // While typing, keep the whole message box in view above the Send button and keyboard.
        .onChange(of: typing) { _, isTyping in
            guard isTyping else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(Motion.standard) { proxy.scrollTo("composer", anchor: .bottom) }
            }
        }
        .onChange(of: text) {
            guard typing else { return }
            proxy.scrollTo("composer", anchor: .bottom)
        }
        }
        // Content scrolling up passes under a band of the background, not under the clock.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
                .background { LookBackground().ignoresSafeArea(edges: .top) }
        }
        // The Send button stays pinned above the tab bar so it's always in reach.
        .safeAreaInset(edge: .bottom) {
            if !desktops.isEmpty {
                sendButton
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                    .background { LookBackground().ignoresSafeArea(edges: .bottom) }
            }
        }
        .sensoryFeedback(.selection, trigger: peerID)
        .background(backdrop)
        // The same scan button, in the same place, as Settings: the navigation bar's trailing item.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startPairing() } label: { Label("Scan Pairing Code", systemImage: "qrcode.viewfinder") }
            }
        }
        .motion(Motion.standard, value: model.lastSendResult)
        .onChange(of: model.justAdded) { _, id in if let id { peerID = id } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Motion.perform { files = urls.compactMap(Self.copyToTemp) }
        }
    }

    private var backdrop: some View {
        LookBackground().ignoresSafeArea()
    }

    /// Logo and a large "Send to" title, like the Mac's Send window.
    private var header: some View {
        HStack(spacing: Space.md) {
            LogoBadge(size: 44).id(model.settings.theme)
            Text("Send to").font(Look.display(34, weight: Look.style == .material ? .regular : nil))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, Space.sm)
    }

    /// Device tiles like the Mac's: the selected one fills with the theme color.
    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)],
                      spacing: Space.md) {
                ForEach(desktops) { device in
                    let selected = device.id == peer?.id
                    Button {
                        Motion.perform { peerID = device.id }
                    } label: {
                        HStack(spacing: Space.md) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Look.selectedInk.opacity(0.12) : Theme.accentTint)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    Image(systemName: selected ? "checkmark" : Theme.symbol(for: device))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(selected ? Look.selectedInk : Look.accentText)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.subheadline.weight(.semibold))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selected ? Look.selectedInk : Look.ink)
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { LookTile(selected: selected) }
                        .contentShape(RoundedRectangle(cornerRadius: LookTile.radius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .overlay(alignment: .bottomLeading) {
                        if !device.isPaired {
                            MissingTokenButton { model.settings.tokenRequest = device.id }
                                .padding(.leading, Space.md + 36 + Space.md).padding(.bottom, Space.md)
                        }
                    }
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
                                detail: photos.isEmpty ? nil : "\(photos.count) selected", selected: !photos.isEmpty)
            }
            .buttonStyle(PressableStyle())
            .frame(height: 260)
            .overlay(alignment: .topTrailing) {
                if !photos.isEmpty { ClearBadge { photos = [] } }
            }
            VStack(spacing: 22) {
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
                .frame(height: 119)
                ActionCard(title: "Files", symbol: "folder.fill",
                           detail: files.isEmpty ? nil : "\(files.count) selected", selected: !files.isEmpty,
                           onClear: { files = [] }) {
                    importing = true
                }
                .frame(height: 119)
            }
        }
        .frame(height: 260)
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
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Text").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                TextField("drip... drip... drip...", text: $text, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($typing)
                    .accessibilityLabel("Text")
            }
            .padding(.top, 6)
        }
        .padding(Space.lg)
        .background {
            LookTile(selected: false)
                .overlay(RoundedRectangle(cornerRadius: LookTile.radius, style: .continuous)
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
                if model.sending { ProgressView() } else { Image(systemName: "paperplane.fill") }
                Text(peer.map { "Send to \($0.name)" } ?? "Send")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xs)
        }
        .buttonStyle(PrimaryStyle())
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

        let exported = attachments.filter { !files.contains($0) }
        let sent = await model.send(payloads, to: peer)
        // Photo exports are temporary copies; picked files are kept until they're sent.
        for file in exported { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        if sent {
            for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
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
        // File-backed, so a long video is copied on disk instead of loaded into memory, and keeps its name.
        for item in items {
            if let picked = try? await item.loadTransferable(type: PickedFile.self) { files.append(picked.url) }
        }
        return files
    }

    private static func copyToTemp(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-pick-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
    }
}

private struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Kicker(text)
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
                    .fill(selected ? Look.selectedInk.opacity(0.12) : Theme.accentTint)
                    .frame(width: 46, height: 46)
                Image(systemName: selected ? "checkmark" : symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Look.selectedInk : Look.accentText)
            }
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail ?? " ")
                .font(.caption2)
                .lineLimit(1)
                .opacity(detail == nil ? 0 : 0.9)
        }
        .foregroundStyle(selected ? Look.selectedInk : Look.ink)
        // Padding goes inside the frame, so a card is exactly as tall as the grid gives it.
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LookTile(selected: selected) }
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
            }
            .buttonStyle(PrimaryStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xxl)
        .background { LookTile(selected: false) }
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
                .listRowBackground(Look.container)
            }

            if model.history.isEmpty {
                Section {
                    ContentUnavailableView("Nothing yet", systemImage: "tray",
                                           description: Text("Things sent to this iPhone appear here."))
                        .listRowBackground(Look.container)
                }
            }

            if !model.newItems.isEmpty {
                Section {
                    ForEach(model.newItems) { row($0).listRowBackground(Look.container) }
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
                    ForEach(model.seenItems) { row($0).listRowBackground(Look.container) }
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
        .background { LookBackground().ignoresSafeArea() }
        .refreshable { await model.collectInbox() }
        .safeAreaInset(edge: .bottom) {
            Button(action: openReceivedFolder) {
                Label("Open received files in Files", systemImage: "folder")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.md)
                    .background { LookTile(selected: false) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Look.accentText)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background { LookBackground().ignoresSafeArea(edges: .bottom) }   // a solid band, so list rows don't show through
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
                    .background(Theme.start, in: Capsule())
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
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != wanted else { return }
        // The public call always shows a "You have changed the icon" alert. This app is installed
        // directly (not through the App Store), so use UIKit's quiet variant when it's there.
        let quiet = NSSelectorFromString("_setAlternateIconName:completionHandler:")
        if app.responds(to: quiet) {
            typealias SetIcon = @convention(c) (NSObject, Selector, NSString?, @escaping @convention(block) (NSError?) -> Void) -> Void
            let setIcon = unsafeBitCast(app.method(for: quiet), to: SetIcon.self)
            setIcon(app, quiet, wanted as NSString?) { _ in }
        } else {
            app.setAlternateIconName(wanted) { _ in }
        }
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
                .foregroundStyle(Look.accentText)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// A tile in the current style: a raised card, or the selected color when chosen.
private struct LookTile: View {
    static var radius: CGFloat { Look.isAtelier ? 4 : 22 }
    var selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Group {
            if selected {
                shape.fill(Look.selectedFill)
                    .shadow(color: Look.style == .spatial ? Theme.end.opacity(0.35) : .clear, radius: 14)
            } else if Look.isAtelier {
                shape.fill(Look.container).overlay(shape.strokeBorder(Look.hairline, lineWidth: 1))
            } else {
                LookSurface(shape: shape)
            }
        }
        .modifier(ClayShadow())
    }
}

/// A photo or video from the Photos picker, copied to its own temporary folder under its original name.
private struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-photo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}
