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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoBadge(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send with Droprr").font(.headline)
                    Text(model.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }

            if model.settings.peers.isEmpty {
                Text("Open Droprr from the menu bar and add a device first.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(model.settings.peers) { peer in
                    Button {
                        Task { await model.send(to: peer) }
                    } label: {
                        VStack(spacing: 6) {
                            GlyphCircle(symbol: model.sentTo == peer.id ? "checkmark" : Theme.symbol(for: peer),
                                        size: 40, filled: true)
                            Text(peer.name).font(.callout.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.loading || model.sending || model.payloads.isEmpty)
                }
            }

            SendStatusView(message: model.status, progress: model.progress)

            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .animation(.default, value: model.status)
    }
}
