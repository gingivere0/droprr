import SwiftUI
import UniformTypeIdentifiers

/// A window to drop files onto a device, or type text to send.
struct SendView: View {
    @Bindable var model: MacModel
    @Environment(\.openSettings) private var openSettings
    @State private var text = ""
    @State private var textPeerID: UUID?

    private var textPeer: Peer? {
        model.settings.peers.first { $0.id == textPeerID } ?? model.settings.lastPeer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                LogoBadge(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Send with Droprr").font(.title3.weight(.semibold))
                    Text("Drop files on a device, or type below.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.settings.peers.isEmpty {
                Text("Add a device in Settings first.")
                    .foregroundStyle(.secondary)
                Button("Open Settings…") {
                    openSettings()
                    bringToFront()
                }
                .buttonStyle(HoverButtonStyle(.prominent))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Space.md)], spacing: Space.md) {
                    ForEach(model.settings.peers) { peer in
                        DropTile(peer: peer, waiting: model.waiting(for: peer)) { files in
                            Task { await model.send(.files(files), to: peer) }
                        } onClick: {
                            model.chooseFiles(for: peer)
                        }
                        .overlay(alignment: .topTrailing) {
                            if model.waiting(for: peer) > 0 {
                                WaitingBadge(count: model.waiting(for: peer), peerName: peer.name) {
                                    model.clearWaiting(for: peer)
                                }
                                .padding(Space.sm)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    TextField("Type or paste text or a link", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.plain)
                        .padding(Space.md)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    HStack {
                        Picker("To", selection: Binding(get: { textPeer?.id }, set: { textPeerID = $0 })) {
                            ForEach(model.settings.peers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .frame(maxWidth: 200)
                        Spacer()
                        Button("Paste & Send") {
                            guard let peer = textPeer else { return }
                            Task { await model.sendClipboard(to: peer) }
                        }
                        .buttonStyle(HoverButtonStyle(.bordered))
                        Button {
                            guard let peer = textPeer else { return }
                            let value = text
                            Task {
                                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                                    await model.send(.url(url), to: peer)
                                } else {
                                    await model.send(.text(value), to: peer)
                                }
                                text = ""
                            }
                        } label: {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(HoverButtonStyle(.prominent))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.isEmpty)
                    }
                }
            }

            SendStatusView(message: model.lastSendResult, progress: model.progress)
        }
        .padding(Space.xl)
        .frame(width: 460)
        .motion(Motion.standard, value: model.lastSendResult)
    }
}

private struct DropTile: View {
    var peer: Peer
    var waiting: Int
    var onDrop: ([URL]) -> Void
    var onClick: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: Space.sm) {
                GlyphCircle(symbol: Theme.symbol(for: peer), size: 44, filled: targeted)
                Text(peer.name).font(.headline).lineLimit(1)
                Text(targeted ? "Release to send" : Theme.platformName(peer.platform))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.lg)
            .background {
                RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                    .fill(targeted ? AnyShapeStyle(Theme.accentTint) : AnyShapeStyle(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                        .strokeBorder(targeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                                      style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5])))
            }
            .scaleEffect(targeted ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHint("Drop files here, or click to choose")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { onDrop(urls) }
            }
            return true
        }
        .motion(Motion.fast, value: targeted)
    }
}
