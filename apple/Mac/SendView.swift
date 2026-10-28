import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @Bindable var model: MacModel
    @State private var peerID: UUID?
    @State private var text = ""
    @State private var importing = false
    @State private var targeted = false

    private var peer: Peer? {
        model.settings.peers.first { $0.id == peerID } ?? model.settings.lastPeer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.settings.peers.isEmpty {
                Text("Add a device in Droprr Settings first.")
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            } else {
                Picker("Send to", selection: Binding(get: { peer?.id }, set: { peerID = $0 })) {
                    ForEach(model.settings.peers) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.largeTitle)
                    Text("Drop files here")
                    Button("Choose Files…") { importing = true }
                }
                .padding()
            }
            .frame(height: 140)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { await drop(providers) }
                return true
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Button("Send Clipboard") {
                    guard let peer else { return }
                    Task { await model.send(clipboardTo: peer) }
                }
                Spacer()
                Button("Send Text") {
                    guard let peer else { return }
                    let value = text
                    Task {
                        await model.send(text: value, to: peer)
                        text = ""
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.isEmpty)
            }
            .disabled(peer == nil)

            if let result = model.lastSendResult {
                Text(result).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 420)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let peer, case .success(let urls) = result else { return }
            Task { await model.send(files: urls, to: peer) }
        }
    }

    private func drop(_ providers: [NSItemProvider]) async {
        guard let peer else { return }
        var urls: [URL] = []
        for provider in providers {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
               let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        await model.send(files: urls, to: peer)
    }
}
