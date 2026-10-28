import AppKit
import SwiftUI

/// "Droprr" in the Mac Share menu (Finder, Safari, Photos…): pick a device and the items go to it.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let model = MacShareModel(context: extensionContext)
        let host = NSHostingView(rootView: MacShareView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        view = host
        Task { await model.load() }
    }
}

@Observable
@MainActor
final class MacShareModel {
    let settings = DroprrSettings.shared
    var payloads: [SendPayload] = []
    var loading = true
    var status: String?
    var progress: Double?
    var sending = false
    var sentTo: UUID?

    @ObservationIgnored private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    var summary: String {
        if loading { return "Preparing…" }
        if payloads.isEmpty { return "Nothing Droprr can send was shared." }
        return payloads.map(\.label).joined(separator: ", ")
    }

    func load() async {
        payloads = await SharedItems.payloads(from: context?.inputItems as? [NSExtensionItem] ?? [])
        loading = false
    }

    func send(to peer: Peer) async {
        settings.lastPeerID = peer.id
        sending = true
        defer { sending = false }
        status = peer.isPhone ? "Queueing for \(peer.name)…" : "Sending to \(peer.name)…"
        var client = DroprrClient(peer: peer, token: settings.token)
        if peer.isPhone {
            // Phones collect from the Mac app's outbox, so hand the items to it on this Mac.
            client = DroprrClient(peer: Peer(name: "This Mac", host: "127.0.0.1", port: settings.port),
                                  token: settings.token, sendPath: "/outbox/\(peer.id.uuidString)")
        }
        do {
            for payload in payloads {
                try await payload.send(with: client) { [weak self] in self?.progress = $0 }
            }
            progress = nil
            sentTo = peer.id
            status = peer.isPhone ? "Waiting for \(peer.name). It arrives when Droprr opens there." : "Sent to \(peer.name)"
            try? await Task.sleep(for: .milliseconds(peer.isPhone ? 1400 : 700))
            context?.completeRequest(returningItems: nil)
        } catch {
            progress = nil
            status = peer.isPhone && (error as? URLError) != nil
                ? "Open the Droprr app on this Mac first, then try again."
                : "Couldn't send: \(error.localizedDescription)"
        }
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

struct MacShareView: View {
    @Bindable var model: MacShareModel
    @State private var selectedID: UUID?

    private var selected: Peer? {
        model.settings.peers.first { $0.id == selectedID } ?? model.settings.lastPeer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                LogoBadge(size: 32)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Send with Droprr").font(.headline)
                    Text(model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }

            if model.settings.peers.isEmpty {
                Text("Open Droprr from the menu bar and add a device first.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: Space.sm) {
                    ForEach(model.settings.peers) { peer in
                        let isSelected = peer.id == selected?.id
                        Button { selectedID = peer.id } label: {
                            HStack(spacing: Space.md) {
                                GlyphCircle(symbol: model.sentTo == peer.id ? "checkmark" : Theme.symbol(for: peer),
                                            size: 32, filled: isSelected)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(peer.name).font(.headline).lineLimit(1)
                                    Text(Theme.platformName(peer.platform)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accentText).fontWeight(.semibold)
                                }
                            }
                            .padding(Space.sm)
                            .background(isSelected ? AnyShapeStyle(Theme.accentTint) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }

            SendStatusView(message: model.status, progress: model.progress)

            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(HoverButtonStyle(.bordered))
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let peer = selected else { return }
                    Task { await model.send(to: peer) }
                } label: {
                    Label("Send", systemImage: "paperplane.fill").fontWeight(.semibold)
                }
                .buttonStyle(HoverButtonStyle(.prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || model.loading || model.sending || model.payloads.isEmpty)
            }
        }
        .padding(Space.lg)
        .frame(width: 380)
        .motion(Motion.standard, value: model.status)
    }
}
