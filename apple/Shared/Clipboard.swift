import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    /// Copies a received item: text, a web link (other schemes as text), an image as image data,
    /// or another file as a file. Marked concealed so clipboard managers don't keep a history of it.
    static func copy(_ item: ReceivedItem) {
        switch item.kind {
        case .text(let text): copy(text: text, concealed: true)
        case .url(let url): copy(url: url, concealed: true)
        case .file(let file): copy(file: file, concealed: true)
        }
    }

    static func copy(file: URL, concealed: Bool = false) {
        let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = []
        if isImage, let image = NSImage(contentsOf: file) { objects.append(image) }
        objects.append(file as NSURL)
        pb.writeObjects(objects)
        if concealed { conceal(pb) }
        #else
        if isImage, let image = UIImage(contentsOfFile: file.path) {
            UIPasteboard.general.image = image
        } else if let type = UTType(filenameExtension: file.pathExtension), let data = try? Data(contentsOf: file) {
            UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        }
        #endif
    }

    static func copy(text: String, concealed: Bool = false) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed { conceal(pb) }
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(url: URL, concealed: Bool = false) {
        guard Links.isWeb(url) else { return copy(text: url.absoluteString, concealed: concealed) }
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.setString(url.absoluteString, forType: .string)
        if concealed { conceal(pb) }
        #else
        UIPasteboard.general.url = url
        #endif
    }

    #if os(macOS)
    /// nspasteboard.org convention: clipboard managers skip items marked concealed.
    private static func conceal(_ pb: NSPasteboard) {
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
    #endif
}
