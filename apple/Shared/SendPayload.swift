import Foundation

/// One thing to send: some text, a link, or a batch of files.
enum SendPayload {
    case text(String)
    case url(URL)
    case files([URL])

    var label: String {
        switch self {
        case .text: return "text"
        case .url: return "link"
        case .files(let files): return files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        }
    }

    func send(with client: DroprrClient) async throws {
        switch self {
        case .text(let text): try await client.send(text: text)
        case .url(let url): try await client.send(url: url)
        case .files(let files): try await client.send(files: files)
        }
    }
}
