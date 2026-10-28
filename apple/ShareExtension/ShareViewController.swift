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
        let client = DroprrClient(peer: peer)
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

    @State private var selectedID: UUID?

    private var desktops: [Peer] { model.settings.peers.filter { !$0.isPhone } }
    private var selected: Peer? {
        desktops.first { $0.id == selectedID } ?? desktops.first { $0.id == model.settings.lastPeerID } ?? desktops.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.md) {
                        GlyphCircle(symbol: summarySymbol, size: 40, filled: true)
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Sharing").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(model.summary).font(.body.weight(.medium)).lineLimit(2)
                        }
                    }
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))

                    Text("SEND TO").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)

                    if desktops.isEmpty {
                        Text("Open the Droprr app and add a computer first.")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)], spacing: Space.md) {
                        ForEach(desktops) { peer in
                            let isSelected = peer.id == selected?.id
                            Button { selectedID = peer.id } label: {
                                VStack(spacing: Space.sm) {
                                    GlyphCircle(symbol: model.sentTo == peer.id ? "checkmark" : Theme.symbol(for: peer),
                                                size: 48)
                                    Text(peer.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(Theme.platformName(peer.platform)).font(.caption)
                                        .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.75) : Color.secondary)
                                }
                                .foregroundStyle(isSelected ? Theme.onAccent : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.lg)
                                .background(isSelected ? AnyShapeStyle(Theme.start) : AnyShapeStyle(Theme.tile),
                                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                    .strokeBorder(isSelected ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.stroke), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        }
                    }

                    SendStatusView(message: model.status, progress: model.progress)
                }
                .padding(Space.lg)
            }
            .background(Theme.surface.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard let peer = selected else { return }
                    Task { await model.send(to: peer) }
                } label: {
                    HStack(spacing: Space.sm) {
                        if model.sending { ProgressView().tint(Theme.onPrimaryButton) } else { Image(systemName: "paperplane.fill") }
                        Text(selected.map { "Send to \($0.name)" } ?? "Send")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.onPrimaryButton)
                    .background(Theme.primaryButton, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || model.loading || model.sending || model.payloads.isEmpty)
                .opacity(selected == nil || model.payloads.isEmpty ? 0.45 : 1)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(.bar)
            }
            .sensoryFeedback(.selection, trigger: selectedID)
            .navigationTitle("Droprr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: Space.sm) {
                        LogoBadge(size: 22)
                        Text("Droprr").font(.headline)
                    }
                }
            }
            .motion(Motion.standard, value: model.status)
        }
        .tint(Theme.accentText)
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
