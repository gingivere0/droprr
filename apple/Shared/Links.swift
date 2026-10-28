import Foundation
#if os(macOS)
import AppKit
import Darwin
#endif

/// Safety rules for received links and files (see "Links are http and https only" in PROTOCOL.md).
enum Links {
    /// Only http and https links are treated as links; everything else is text.
    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    #if os(macOS)
    /// Opens a web link; anything else is copied as text instead of being opened.
    static func open(_ url: URL) {
        guard isWeb(url) else {
            Clipboard.copy(text: url.absoluteString, concealed: true)
            return
        }
        NSWorkspace.shared.open(url)
    }
    #endif

    /// Marks a received file as downloaded from the internet, so macOS shows its usual warning
    /// before opening it (com.apple.quarantine). No-op on iOS.
    static func quarantine(_ file: URL) {
        #if os(macOS)
        let value = String(format: "0083;%llx;Droprr;", UInt64(Date().timeIntervalSince1970))
        _ = file.path.withCString { path in
            value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
        #endif
    }
}
