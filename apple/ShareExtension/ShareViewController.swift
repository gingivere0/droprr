import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Droprr" in the iOS share sheet: pick a device and the shared items go straight to it.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@Observable
@MainActor
final class ShareModel {
    let settings = DroprrSettings.shared
    var payloads: [SendPayload] = []
    var loading = true
    var status: String?
    var sending = false
    var progress: Double?
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
        status = "Sending to \(peer.name)…"
        let client = DroprrClient(peer: peer, token: settings.token)
        do {
            for payload in payloads {
                try await payload.send(with: client) { [weak self] in self?.progress = $0 }
            }
            progress = nil
            sentTo = peer.id
            status = "Sent to \(peer.name)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(for: .milliseconds(600))
            context?.completeRequest(returningItems: nil)
        } catch {
            progress = nil
            status = "Couldn't send: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}


struct ShareView: View {
    @Bindable var model: ShareModel

    private var desktops: [Peer] { model.settings.peers.filter { !$0.isPhone } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        GlyphCircle(symbol: summarySymbol, size: 40, filled: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sharing").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(model.summary).font(.body.weight(.medium)).lineLimit(2)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("SEND TO").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)

                    if desktops.isEmpty {
                        Text("Open the Droprr app and add a computer first.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(desktops) { peer in
                            Button {
                                Task { await model.send(to: peer) }
                            } label: {
                                VStack(spacing: 10) {
                                    GlyphCircle(symbol: model.sentTo == peer.id ? "checkmark" : Theme.symbol(for: peer),
                                                size: 50, filled: true)
                                    Text(peer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if peer.id == model.settings.lastPeerID {
                                        Text("Last used").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.loading || model.sending || model.payloads.isEmpty)
                        }
                    }

                    SendStatusView(message: model.status, progress: model.progress)
                }
                .padding(20)
            }
            .background(Theme.gradient.opacity(0.10).ignoresSafeArea())
            .navigationTitle("Droprr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        LogoBadge(size: 22)
                        Text("Droprr").font(.headline)
                    }
                }
            }
            .animation(.default, value: model.status)
        }
        .tint(Theme.start)
    }

    private var summarySymbol: String {
        switch model.payloads.first {
        case .url: return "link"
        case .text: return "text.alignleft"
        case .files: return "doc.fill"
        case nil: return "square.and.arrow.up"
        }
    }
}
