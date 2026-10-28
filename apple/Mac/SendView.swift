import SwiftUI
import UniformTypeIdentifiers

/// The Send window: pick a device, add files and/or text, then Send (⌘↩).
/// Dropping files straight onto a device card still sends them right away.
struct SendView: View {
    @Bindable var model: MacModel
    @Environment(\.openSettings) private var openSettings
    @State private var selectedID: UUID?
    @State private var files: [URL] = []
    @State private var text = ""
    @State private var dropTargeted = false
    @FocusState private var typing: Bool

    private var selected: Peer? {
        model.settings.peers.first { $0.id == selectedID } ?? model.settings.lastPeer
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !files.isEmpty || !trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header

            if model.settings.peers.isEmpty {
                emptyState
            } else {
                devices
                dropArea
                composer
                SendStatusView(message: model.lastSendResult, progress: model.progress)
                bottomBar
            }
        }
        .padding(Space.xl)
        .frame(width: 560)
        .background { WindowGlow().ignoresSafeArea() }
        .seamlessWindow()
        .motion(Motion.standard, value: model.lastSendResult)
        .motion(Motion.fast, value: files)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Space.lg) {
            LogoBadge(size: 48)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Send").font(.largeTitle.weight(.bold))
                Text(selected.map { "To \($0.name) · drop files or type below" } ?? "Choose a device to send to")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.lg) {
            GradientTile(symbol: "point.3.connected.trianglepath.dotted", size: 64, glowing: true)
            Text("No devices yet").font(.title3.weight(.semibold))
            Text("Pair your iPhone or add your PC in Settings to start sending.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Open Settings…") {
                openSettings()
                bringToFront()
            }
            .buttonStyle(HoverButtonStyle(.prominent))
            .keyboardShortcut(",")
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xxl)
        .card()
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Send to")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: Space.md)],
                      alignment: .leading, spacing: Space.md) {
                ForEach(Array(model.settings.peers.enumerated()), id: \.element.id) { index, peer in
                    DeviceCard(peer: peer, selected: peer.id == selected?.id,
                               waiting: model.waiting(for: peer),
                               onSelect: { selectedID = peer.id },
                               onDropFiles: { urls in Task { await model.send(.files(urls), to: peer) } },
                               onClearWaiting: { model.clearWaiting(for: peer) })
                        // ⌘1…⌘9 pick a device.
                        .background {
                            if index < 9 {
                                Button("") { selectedID = peer.id }
                                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                                    .hidden()
                            }
                        }
                }
            }
        }
    }

    private var dropArea: some View {
        VStack(spacing: Space.md) {
            if files.isEmpty {
                GradientTile(symbol: dropTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down.on.square",
                             size: 56, glowing: dropTargeted)
                    .scaleEffect(dropTargeted ? 1.08 : 1)
                VStack(spacing: Space.xs) {
                    Text(dropTargeted ? "Release to add" : "Drop files here").font(.title3.weight(.semibold))
                    Text("Photos, documents, anything. Or choose them from Finder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Choose Files…") { addFiles() }
                    .buttonStyle(HoverButtonStyle(.bordered))
                    .keyboardShortcut("o")
            } else {
                HStack {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") ready").font(.headline)
                    Spacer()
                    Button("Add More…") { addFiles() }
                        .buttonStyle(HoverButtonStyle(.plain))
                        .foregroundStyle(Theme.accentText)
                        .keyboardShortcut("o")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.sm)], spacing: Space.sm) {
                    ForEach(files, id: \.self) { file in
                        FileChip(file: file) { files.removeAll { $0 == file } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(Space.lg)
        .background {
            RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                .fill(dropTargeted ? AnyShapeStyle(Theme.accentTint) : AnyShapeStyle(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                    .strokeBorder(dropTargeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.accentText.opacity(0.35)),
                                  style: StrokeStyle(lineWidth: 2, dash: dropTargeted ? [] : [8, 6])))
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { files += await Self.fileURLs(from: providers).filter { !files.contains($0) } }
            return true
        }
        .motion(Motion.fast, value: dropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(files.isEmpty ? "Drop area. Drop files here or choose files." : "\(files.count) files ready")
    }

    private var composer: some View {
        HStack(alignment: .top, spacing: Space.md) {
            ColorTile(symbol: "text.bubble.fill", color: Theme.start, size: 28)
            TextField("Add a message or paste a link", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($typing)
                .padding(.top, Space.xs)
        }
        .card(highlighted: typing)
        .motion(Motion.fast, value: typing)
    }

    private var bottomBar: some View {
        HStack(spacing: Space.md) {
            Button {
                guard let peer = selected else { return }
                Task { await model.sendClipboard(to: peer) }
            } label: {
                Label("Send Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(HoverButtonStyle(.bordered))
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .hoverHint("Send what's on the clipboard (⇧⌘V)")
            .disabled(selected == nil || model.isSending)

            Spacer()

            Button {
                guard let peer = selected else { return }
                Task { await sendStaged(to: peer) }
            } label: {
                HStack(spacing: Space.sm) {
                    if model.isSending { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "paperplane.fill") }
                    Text(selected.map { "Send to \($0.name)" } ?? "Send")
                }
                .font(.headline)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
            }
            .buttonStyle(HoverButtonStyle(.prominent))
            .shadow(color: Theme.start.opacity(hasContent ? 0.35 : 0), radius: 10, y: 4)
            .keyboardShortcut(.return, modifiers: .command)
            .hoverHint("Send the files and message (⌘↩)")
            .disabled(selected == nil || !hasContent || model.isSending)
        }
    }

    // MARK: Actions

    private func addFiles() {
        files += model.pickFiles().filter { !files.contains($0) }
    }

    private func sendStaged(to peer: Peer) async {
        var payloads: [SendPayload] = []
        if !trimmed.isEmpty {
            if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                payloads.append(.url(url))
            } else {
                payloads.append(.text(text))
            }
        }
        if !files.isEmpty { payloads.append(.files(files)) }
        if await model.send(payloads, to: peer) {
            Motion.perform {
                files = []
                text = ""
            }
        }
    }

    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
               let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        return urls
    }
}

struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A selectable device card. Dropping files on it sends them to that device immediately.
private struct DeviceCard: View {
    var peer: Peer
    var selected: Bool
    var waiting: Int
    var onSelect: () -> Void
    var onDropFiles: ([URL]) -> Void
    var onClearWaiting: () -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: Space.sm) {
                ZStack(alignment: .bottomTrailing) {
                    GradientTile(symbol: Theme.symbol(for: peer), size: 52, glowing: selected || targeted)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .offset(x: Space.sm, y: Space.sm)
                    }
                }
                VStack(spacing: 0) {
                    Text(peer.name).font(.headline).lineLimit(1)
                    Text(targeted ? "Release to send now" : Theme.platformName(peer.platform))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 128)
            .padding(.vertical, Space.lg)
            .background {
                RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                    .fill(selected || targeted ? AnyShapeStyle(Theme.accentTint)
                          : hovering ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                        .strokeBorder(selected || targeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                                      lineWidth: selected || targeted ? 2 : 1))
                    .shadow(color: selected ? Theme.start.opacity(0.2) : .clear, radius: 10, y: 4)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if waiting > 0 {
                WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting)
                    .padding(Space.xs)
            }
        }
        .onHover { hovering = $0 }
        .hoverHint("Send to \(peer.name). Drop files here to send them right away.")
        .accessibilityLabel("\(peer.name), \(Theme.platformName(peer.platform))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await SendView.fileURLs(from: providers)
                if !urls.isEmpty { onDropFiles(urls) }
            }
            return true
        }
        .motion(Motion.fast, value: selected)
        .motion(Motion.fast, value: targeted)
        .motion(Motion.fast, value: hovering)
    }
}

/// A staged file as a colorful chip with its type icon.
private struct FileChip: View {
    var file: URL
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            ColorTile(symbol: Theme.symbol(for: ReceivedItem(kind: .file(file))), color: Theme.start, size: 24)
            Text(file.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(file.lastPathComponent)")
        }
        .padding(Space.sm)
        .background(.background, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.stroke))
    }
}
