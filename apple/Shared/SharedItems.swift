import Foundation
import UniformTypeIdentifiers

/// Turns what a share sheet hands an extension into things Droprr can send. Used by both share extensions.
enum SharedItems {
    static func payloads(from items: [NSExtensionItem]) async -> [SendPayload] {
        var payloads: [SendPayload] = []
        var files: [URL] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            switch await load(provider) {
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
        return payloads
    }

    private static func load(_ provider: NSItemProvider) async -> SendPayload? {
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

    private static func copy(_ source: URL, as name: String? = nil) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name ?? source.lastPathComponent)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.copyItem(at: source, to: dest)) != nil ? dest : nil
    }
}
