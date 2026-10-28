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
        var client = DroprrClient(peer: peer)
        if peer.isPhone {
            // Phones collect from the Mac app's outbox, so hand the items to it on this Mac.
            client = DroprrClient(peer: Peer(name: "This Mac", host: "127.0.0.1", port: settings.port, token: settings.token),
                                  sendPath: "/outbox/\(peer.id.uuidString)")
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
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Kicker("Droprr")
                        Text("Send").font(Atelier.serif(28))
                    }
                    Spacer()
                    LogoBadge(size: 28).padding(.bottom, 4)
                }
                Text(model.summary).font(.system(size: 12)).foregroundStyle(Atelier.muted).lineLimit(2)
                Hairline()
            }

            if model.settings.peers.isEmpty {
                Text("Open Droprr from the menu bar and add a device first.")
                    .foregroundStyle(Atelier.muted)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Kicker("Send to")
                    VStack(spacing: 0) {
                        ForEach(model.settings.peers) { peer in
                            let isSelected = peer.id == selected?.id
                            Button { selectedID = peer.id } label: {
                                HStack(spacing: Space.md) {
                                    Image(systemName: model.sentTo == peer.id ? "checkmark" : Theme.symbol(for: peer))
                                        .font(.system(size: 13))
                                        .foregroundStyle(isSelected ? Atelier.ink : Atelier.muted)
                                        .frame(width: 18)
                                    Text(peer.name).font(Atelier.serif(16)).lineLimit(1)
                                    Text(Theme.platformName(peer.platform)).font(.system(size: 11)).foregroundStyle(Atelier.muted)
                                    Spacer()
                                    if isSelected { Circle().fill(Theme.end).frame(width: 6, height: 6) }
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, Space.xs)
                                .background(isSelected ? Theme.secondaryTint.opacity(0.6) : .clear)
                                .overlay(alignment: .bottom) { Hairline() }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }

            SendStatusView(message: model.status, progress: model.progress)

            HStack(spacing: Space.lg) {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(AtelierLinkStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let peer = selected else { return }
                    Task { await model.send(to: peer) }
                } label: {
                    HStack(spacing: Space.sm) {
                        Text("Send")
                        Image(systemName: "arrow.right").foregroundStyle(Theme.end)
                    }
                }
                .buttonStyle(AtelierPrimaryStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || model.loading || model.sending || model.payloads.isEmpty)
            }
        }
        .foregroundStyle(Atelier.ink)
        .padding(22)
        .frame(width: 380)
        .background(Atelier.paper)
        .motion(Motion.standard, value: model.status)
    }
}
