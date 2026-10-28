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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
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
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(model.settings.peers) { peer in
                        DropTile(peer: peer, waiting: model.waiting(for: peer)) { files in
                            Task { await model.send(.files(files), to: peer) }
                        } onClick: {
                            model.chooseFiles(for: peer)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Type or paste text or a link", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.start)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.isEmpty)
                    }
                }
            }

            SendStatusView(message: model.lastSendResult, progress: model.progress)
        }
        .padding(20)
        .frame(width: 460)
        .animation(.default, value: model.lastSendResult)
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
            VStack(spacing: 8) {
                GlyphCircle(symbol: Theme.symbol(for: peer), size: 44, filled: targeted)
                Text(peer.name).font(.headline).lineLimit(1)
                Text(waiting > 0 ? "\(waiting) waiting" : (targeted ? "Release to send" : Theme.platformName(peer.platform)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(targeted ? AnyShapeStyle(Theme.start.opacity(0.10)) : AnyShapeStyle(.background.secondary))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(targeted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary),
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
        .animation(.spring(duration: 0.2), value: targeted)
    }
}
