import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A file attached to a user message. The bytes live on disk in
/// ~/Library/Application Support/ClaudeChat/attachments; only this metadata goes in the chat history.
struct Attachment: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case image, pdf, text
    }

    var id = UUID()
    var kind: Kind
    var name: String          // original file name, shown in the UI
    var mediaType: String     // image/jpeg, image/png, application/pdf, text/plain
    var storedFile: String    // file name inside the attachments folder
    var byteCount: Int

    var url: URL { AttachmentStore.directory.appendingPathComponent(storedFile) }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var symbol: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        }
    }
}

struct AttachmentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AttachmentStore {
    /// Long edge for images sent to Claude. Bigger images cost more tokens without much benefit for chat.
    static let maxImageEdge = 2000
    static let maxImageBytes = 4_500_000
    static let maxPDFBytes = 20_000_000          // the whole request must stay under 32 MB once base64-encoded
    static let maxTextCharacters = 500_000

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeChat/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"]

    // MARK: Creating attachments

    static func make(from url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .data

        if type.conforms(to: .pdf) {
            let data = try read(url, name: name)
            guard data.count <= maxPDFBytes else {
                throw AttachmentError(message: "\(name) is too large (\(fmt(data.count))). PDFs can be up to \(fmt(maxPDFBytes)).")
            }
            return try save(data, kind: .pdf, name: name, mediaType: "application/pdf", ext: "pdf")
        }

        if type.conforms(to: .image) {
            let data = try read(url, name: name)
            return try makeImage(from: data, name: name)
        }

        if richTextExtensions.contains(ext) {
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw AttachmentError(message: "Couldn't read the text in \(name).")
            }
            return try makeText(attributed.string, name: name)
        }

        // Anything else: accept it if it's readable text (code, csv, json, md, logs…).
        let data = try read(url, name: name)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw AttachmentError(message: "\(name) isn't a supported type. Attach images, PDFs, or text-based files (txt, md, csv, code, Word, RTF).")
        }
        return try makeText(text, name: name)
    }

    /// For images pasted from the clipboard or dropped as image data.
    static func make(fromImage image: NSImage, name: String = "Pasted image") throws -> Attachment {
        guard let tiff = image.tiffRepresentation else {
            throw AttachmentError(message: "Couldn't read the image on the clipboard.")
        }
        return try makeImage(from: tiff, name: name)
    }

    /// Re-encodes every image through ImageIO: applies EXIF rotation (Claude doesn't read metadata),
    /// converts HEIC/TIFF/etc. to JPEG or PNG, and caps the long edge at `maxImageEdge`.
    private static func makeImage(from data: Data, name: String) throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw AttachmentError(message: "\(name) isn't an image macOS can read.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? maxImageEdge
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? maxImageEdge
        let longEdge = max(1, min(maxImageEdge, max(w, h)))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError(message: "Couldn't decode \(name).")
        }

        let hasAlpha: Bool
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }

        var encoded: Data?
        var mediaType = "image/jpeg"
        var ext = "jpg"
        if hasAlpha {
            encoded = encode(cg, type: .png, quality: nil)
            mediaType = "image/png"
            ext = "png"
            if let e = encoded, e.count > maxImageBytes { encoded = nil }   // too big as PNG: fall back to JPEG
        }
        if encoded == nil {
            mediaType = "image/jpeg"
            ext = "jpg"
            encoded = encode(cg, type: .jpeg, quality: 0.85)
            if let e = encoded, e.count > maxImageBytes {
                encoded = encode(cg, type: .jpeg, quality: 0.6)
            }
        }
        guard let out = encoded else {
            throw AttachmentError(message: "Couldn't convert \(name).")
        }
        let base = (name as NSString).deletingPathExtension
        return try save(out, kind: .image, name: base.isEmpty ? name : "\(base).\(ext)", mediaType: mediaType, ext: ext)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let q = quality { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: buffer)
    }

    private static func makeText(_ text: String, name: String) throws -> Attachment {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AttachmentError(message: "\(name) has no readable text.")
        }
        guard text.count <= maxTextCharacters else {
            throw AttachmentError(message: "\(name) is too long (\(text.count.formatted()) characters). The limit is \(maxTextCharacters.formatted()).")
        }
        return try save(Data(text.utf8), kind: .text, name: name, mediaType: "text/plain", ext: "txt")
    }

    private static func read(_ url: URL, name: String) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AttachmentError(message: "Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    private static func save(_ data: Data, kind: Attachment.Kind, name: String, mediaType: String, ext: String) throws -> Attachment {
        let id = UUID()
        let stored = "\(id.uuidString).\(ext)"
        do {
            try data.write(to: directory.appendingPathComponent(stored), options: .atomic)
        } catch {
            throw AttachmentError(message: "Couldn't save \(name): \(error.localizedDescription)")
        }
        return Attachment(id: id, kind: kind, name: name, mediaType: mediaType, storedFile: stored, byteCount: data.count)
    }

    static func delete(_ a: Attachment) {
        try? FileManager.default.removeItem(at: a.url)
    }

    private static func fmt(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: API content blocks

    static func blocks(for a: Attachment) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: a.url) else {
            return [["type": "text", "text": "[Attachment \"\(a.name)\" is no longer available.]"]]
        }
        switch a.kind {
        case .image:
            return [
                ["type": "text", "text": "Image: \(a.name)"],
                ["type": "image",
                 "source": ["type": "base64", "media_type": a.mediaType, "data": data.base64EncodedString()]],
            ]
        case .pdf:
            return [
                ["type": "document",
                 "title": a.name,
                 "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]],
            ]
        case .text:
            let text = String(decoding: data, as: UTF8.self)
            return [["type": "text", "text": "<file name=\"\(a.name)\">\n\(text)\n</file>"]]
        }
    }

    // MARK: Thumbnails

    private static let thumbCache = NSCache<NSString, NSImage>()

    static func thumbnail(for a: Attachment) -> NSImage? {
        guard a.kind == .image else { return nil }
        let key = a.storedFile as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOf: a.url) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }
}
