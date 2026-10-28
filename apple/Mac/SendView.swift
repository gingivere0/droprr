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
        VStack(alignment: .leading, spacing: Space.lg) {
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
        .frame(width: 520)
        .motion(Motion.standard, value: model.lastSendResult)
        .motion(Motion.fast, value: files)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Space.md) {
            LogoBadge(size: 32)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Send with Droprr").font(.title2.weight(.semibold))
                Text("Choose a device, add files or text, then Send.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle).foregroundStyle(Theme.accentText)
            Text("Add your PC or pair your iPhone in Settings to start sending.")
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
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("To")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Space.md)], spacing: Space.md) {
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
        VStack(spacing: Space.sm) {
            if files.isEmpty {
                Image(systemName: "arrow.down.doc")
                    .font(.title)
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                Text(dropTargeted ? "Release to add" : "Drop files here")
                    .font(.headline)
                Button("Choose Files…") { addFiles() }
                    .buttonStyle(HoverButtonStyle(.bordered, compact: true))
                    .keyboardShortcut("o")
            } else {
                ForEach(files, id: \.self) { file in
                    FileRow(file: file) { files.removeAll { $0 == file } }
                }
                Button("Add More…") { addFiles() }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .foregroundStyle(Theme.accentText)
                    .keyboardShortcut("o")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Space.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                .fill(dropTargeted ? AnyShapeStyle(Theme.accentTint) : AnyShapeStyle(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                    .strokeBorder(dropTargeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [] : [6, 4])))
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { files += await Self.fileURLs(from: providers).filter { !files.contains($0) } }
            return true
        }
        .motion(Motion.fast, value: dropTargeted)
        .accessibilityLabel(files.isEmpty ? "Drop area. Drop files here or choose files." : "\(files.count) files added")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Text or link")
            TextField("Type or paste something", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($typing)
                .padding(Space.md)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(typing ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(Theme.stroke), lineWidth: typing ? 2 : 1))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Space.sm) {
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
                Label(selected.map { "Send to \($0.name)" } ?? "Send", systemImage: "paperplane.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(HoverButtonStyle(.prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .hoverHint("Send the files and text above (⌘↩)")
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
            HStack(spacing: Space.md) {
                GlyphCircle(symbol: Theme.symbol(for: peer), size: 36, filled: selected || targeted)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(peer.name).font(.headline).lineLimit(1)
                    Text(targeted ? "Release to send now" : Theme.platformName(peer.platform))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(selected || targeted || hovering ? AnyShapeStyle(Theme.accentTint) : AnyShapeStyle(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(selected || targeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                                      lineWidth: selected || targeted ? 2 : 1))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
    }
}

private struct FileRow: View {
    var file: URL
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "doc").foregroundStyle(Theme.accentText)
            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(HoverButtonStyle(.plain))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(file.lastPathComponent)")
        }
        .font(.callout)
        .padding(.horizontal, Space.sm)
    }
}
