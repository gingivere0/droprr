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
        .padding(.horizontal, 36)
        .padding(.top, Space.lg)
        .padding(.bottom, 28)
        .frame(width: 600)
        .foregroundStyle(Atelier.ink)
        .background { Atelier.paper.ignoresSafeArea() }
        .seamlessWindow()
        .motion(Motion.standard, value: model.lastSendResult)
        .motion(Motion.fast, value: files)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .bottom, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Kicker("Droprr")
                    Text("Send").font(Atelier.serif(40))
                }
                Spacer()
                LogoBadge(size: 40).padding(.bottom, 6)
            }
            Hairline()
        }
        // The gear floats in the top-right corner without changing the header's layout.
        .overlay(alignment: .topTrailing) {
            Button {
                openSettings()
                bringToFront()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(HoverButtonStyle(.plain))
            .foregroundStyle(Atelier.muted)
            .accessibilityLabel("Settings")
            .hoverHint("Settings (⌘,)")
            .keyboardShortcut(",")
            .offset(y: -22)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("No devices yet").font(Atelier.serif(24))
            Text("Pair your iPhone or add your PC in Settings to start sending.")
                .foregroundStyle(Atelier.muted)
            Button("Open Settings") {
                openSettings()
                bringToFront()
            }
            .buttonStyle(AtelierPrimaryStyle())
            .keyboardShortcut(",")
            .padding(.top, Space.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.lg)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Kicker("Send to")
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(model.settings.peers.enumerated()), id: \.element.id) { index, peer in
                    DeviceTab(peer: peer, selected: peer.id == selected?.id,
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
                Spacer(minLength: 0)
            }
        }
    }

    private var dropArea: some View {
        VStack(spacing: Space.md) {
            if files.isEmpty {
                Image(systemName: dropTargeted ? "arrow.down" : "arrow.down.to.line")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(dropTargeted ? Theme.end : Atelier.muted)
                Text(dropTargeted ? "Release to add" : "Drop files here").font(Atelier.serif(24))
                Button("or choose from Finder") { addFiles() }
                    .buttonStyle(AtelierLinkStyle())
                    .keyboardShortcut("o")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Kicker("\(files.count) file\(files.count == 1 ? "" : "s")")
                    Spacer()
                    Button("Add more") { addFiles() }
                        .buttonStyle(AtelierLinkStyle())
                        .keyboardShortcut("o")
                }
                VStack(spacing: 0) {
                    ForEach(files, id: \.self) { file in
                        FileRow(file: file) { files.removeAll { $0 == file } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 170)
        .padding(Space.xl)
        .background {
            ZStack {
                Rectangle().fill(dropTargeted ? Theme.secondaryTint : Atelier.paper)
                if files.isEmpty { Stripes().foregroundStyle(Atelier.stripe) }
                Rectangle().strokeBorder(dropTargeted ? Atelier.ink : Atelier.hairline, lineWidth: 1)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { files += await Self.fileURLs(from: providers).filter { !files.contains($0) } }
            return true
        }
        .motion(Motion.fast, value: dropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(files.isEmpty ? "Drop area. Drop files here or choose files." : "\(files.count) files ready")
    }

    /// A message or link to send along, written on an underlined line.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Kicker("Message")
            TextField("", text: $text,
                      prompt: Text("Add a message or paste a link").font(Atelier.serif(16)).italic(),
                      axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($typing)
                .padding(.vertical, 6)
            Rectangle()
                .fill(typing ? Atelier.ink : Atelier.hairline)
                .frame(height: 1)
        }
        .motion(Motion.fast, value: typing)
    }

    private var bottomBar: some View {
        HStack(spacing: Space.md) {
            Button {
                guard let peer = selected else { return }
                Task { await model.sendClipboard(to: peer) }
            } label: {
                Text("Send clipboard")
            }
            .buttonStyle(AtelierLinkStyle())
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .hoverHint("Send what's on the clipboard (⇧⌘V)")
            .disabled(selected == nil || model.isSending)

            Spacer()

            Button {
                guard let peer = selected else { return }
                Task { await sendStaged(to: peer) }
            } label: {
                HStack(spacing: Space.sm) {
                    Text(selected.map { "Send to \($0.name)" } ?? "Send")
                    if model.isSending { ProgressView().controlSize(.small).tint(Theme.onPrimaryButton) }
                    else { Image(systemName: "arrow.right").foregroundStyle(Theme.end) }
                }
            }
            .buttonStyle(AtelierPrimaryStyle())
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

/// A device as a text tab: the selected one is underlined with a small dot in the theme's
/// second color. Dropping files on it sends them to that device immediately.
private struct DeviceTab: View {
    var peer: Peer
    var selected: Bool
    var waiting: Int
    var onSelect: () -> Void
    var onDropFiles: ([URL]) -> Void
    var onClearWaiting: () -> Void
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Image(systemName: Theme.symbol(for: peer))
                            .font(.system(size: 13))
                            .foregroundStyle(selected || targeted ? Atelier.ink : Atelier.muted)
                        Text(peer.name)
                            .font(Atelier.serif(18))
                            .foregroundStyle(selected || targeted || hovering ? Atelier.ink : Atelier.muted)
                            .lineLimit(1)
                        if selected {
                            Circle().fill(Theme.end).frame(width: 6, height: 6)
                        }
                    }
                    Rectangle()
                        .fill(selected || targeted ? Theme.primaryButton : hovering ? Atelier.hairline : .clear)
                        .frame(height: 2)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if targeted {
                Text("Release to send now").font(.system(size: 11)).foregroundStyle(Atelier.muted)
            } else if waiting > 0 {
                WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting)
            } else {
                Text(Theme.platformName(peer.platform)).font(.system(size: 11)).foregroundStyle(Atelier.muted)
            }
        }
        .onHover { hovering = $0 }
        .hoverHint("Send to \(peer.name). Drop files here to send them right away.")
        .accessibilityElement(children: .combine)
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

/// A staged file: its type icon, name, and a remove button, over a hairline.
private struct FileRow: View {
    var file: URL
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.md) {
                Image(systemName: Theme.symbol(for: ReceivedItem(kind: .file(file))))
                    .foregroundStyle(Atelier.muted)
                    .frame(width: 18)
                Text(file.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(HoverButtonStyle(.plain))
                    .foregroundStyle(Atelier.muted)
                    .accessibilityLabel("Remove \(file.lastPathComponent)")
            }
            .padding(.vertical, Space.sm)
        }
    }
}
