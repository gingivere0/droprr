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
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var files: [URL] = []
        for provider in providers {
            switch await Self.load(provider) {
            case .files(let urls): files += urls
            case .some(let other): payloads.append(other)
            case nil: break
            }
        }
        // Safari shares a link plus its page title as text; the link is what matters.
        if payloads.contains(where: { if case .url = $0 { return true } else { return false } }) {
            payloads.removeAll { if case .text = $0 { return true } else { return false } }
        }
        if !files.isEmpty { payloads.append(.files(files)) }
        loading = false
    }

    func send(to peer: Peer) async {
        settings.lastPeerID = peer.id
        sending = true
        defer { sending = false }
        status = "Sending to \(peer.name)…"
        let client = DroprrClient(peer: peer, token: settings.token)
        do {
            for payload in payloads { try await payload.send(with: client) }
            status = "Sent to \(peer.name)."
            try? await Task.sleep(for: .milliseconds(600))
            context?.completeRequest(returningItems: nil)
        } catch {
            status = "Couldn't send: \(error.localizedDescription)"
        }
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    nonisolated private static func load(_ provider: NSItemProvider) async -> SendPayload? {
        let fileURL = UTType.fileURL.identifier
        let url = UTType.url.identifier
        if provider.hasItemConformingToTypeIdentifier(url) && !provider.hasItemConformingToTypeIdentifier(fileURL) {
            if let item = try? await provider.loadItem(forTypeIdentifier: url) {
                if let link = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
                    return link.isFileURL ? copy(link).map { .files([$0]) } : .url(link)
                }
            }
        }
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let isPlainText = !types.isEmpty && types.allSatisfy { $0.conforms(to: .text) } && !provider.hasItemConformingToTypeIdentifier(fileURL)
        if isPlainText, let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
            if let text = item as? String { return .text(text) }
            if let data = item as? Data { return .text(String(decoding: data, as: UTF8.self)) }
        }
        // Everything else (photos, videos, documents) as a file.
        guard let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .package) })?.identifier
                ?? provider.registeredTypeIdentifiers.first else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { temp, _ in
                // The system deletes `temp` when this returns, so copy it out first.
                var name = temp?.lastPathComponent ?? "Shared item"
                if let suggested = provider.suggestedName, !suggested.isEmpty {
                    let ext = temp?.pathExtension ?? ""
                    name = ext.isEmpty || suggested.hasSuffix(".\(ext)") ? suggested : "\(suggested).\(ext)"
                }
                continuation.resume(returning: temp.flatMap { copy($0, as: name) }.map { .files([$0]) })
            }
        }
    }

    nonisolated private static func copy(_ source: URL, as name: String? = nil) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name ?? source.lastPathComponent)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.copyItem(at: source, to: dest)) != nil ? dest : nil
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            List {
                Section("Sharing") {
                    Text(model.summary).lineLimit(3)
                }
                Section("Send to") {
                    if model.settings.peers.isEmpty {
                        Text("Open the Droprr app and add a device first.")
                    }
                    ForEach(model.settings.peers) { peer in
                        Button {
                            Task { await model.send(to: peer) }
                        } label: {
                            HStack {
                                Label(peer.name, systemImage: "desktopcomputer")
                                Spacer()
                                if peer.id == model.settings.lastPeerID {
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(model.loading || model.sending || model.payloads.isEmpty)
                    }
                }
                if let status = model.status {
                    Section { Text(status) }
                }
            }
            .navigationTitle("Droprr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
            }
        }
    }
}
