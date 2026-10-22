import SwiftUI
import AppKit

@MainActor
struct MessageRow: View {
    @Environment(ChatStore.self) private var store
    let message: ChatMessage
    let conversationID: UUID
    @State private var editing = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        SentAttachments(attachments: message.attachments)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.15)))
                    }
                    HStack(spacing: 10) {
                        Button {
                            editing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help("Edit and resend as a new branch")
                        Button {
                            store.branch(from: conversationID, at: message.id, including: true)
                        } label: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .help("Branch the chat from here")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .disabled(store.isStreaming)
                }
            }
            .sheet(isPresented: $editing) {
                EditResendSheet(conversationID: conversationID, message: message)
                    .environment(store)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(message.thinking)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                }

                if message.text.isEmpty {
                    if message.error == nil && store.isQueued(message.id) {
                        Label("Queued at half price. The reply usually arrives within the hour, and you'll get a notification.",
                              systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if message.error == nil && store.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    MarkdownText(message.text)
                }

                if let e = message.error {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let u = message.usage {
                Text("\(ModelOption.find(message.modelID ?? "").name) · \(Fmt.tokens(u.promptTokens)) in · \(Fmt.tokens(u.outputTokens)) out · \(Fmt.money(message.cost ?? 0))")
                if u.cacheReadTokens > 0 {
                    Text("· \(Fmt.tokens(u.cacheReadTokens)) from cache")
                }
            }
            if !message.text.isEmpty {
                Button {
                    Pasteboard.copy(message.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy reply")
                Button {
                    Speaker.shared.toggle(message.text)
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .help("Read aloud (click again to stop)")
                Button {
                    store.branch(from: conversationID, at: message.id, including: true)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Branch the chat from here")
                .disabled(store.isStreaming)
            }
            if !message.text.isEmpty || message.error != nil {
                Button {
                    store.retry(conversationID, replyID: message.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Try again on a new branch (keeps this answer)")
                .disabled(store.isStreaming)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Lightweight Markdown

/// Renders inline Markdown (bold, italics, `code`, links) plus fenced code blocks,
/// headings and bullet lists, which is what Claude's replies mostly use.
@MainActor
struct MarkdownText: View {
    private let segments: [Segment]

    init(_ text: String) {
        segments = Segment.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments) { seg in
                switch seg.kind {
                case .prose:
                    Text(Self.attributed(seg.text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language):
                    CodeBlock(code: seg.text, language: language)
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        let prepared = preprocess(s)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(s)
    }

    /// Inline-only parsing ignores block syntax, so turn headings and bullets into readable text.
    static func preprocess(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let title = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? line : "**\(title)**"
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                let indent = String(line.prefix(while: { $0 == " " }))
                return indent + "•  " + String(t.dropFirst(2))
            }
            return line
        }
        .joined(separator: "\n")
    }
}

struct Segment: Identifiable {
    enum Kind {
        case prose
        case code(String)
    }

    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var buffer: [String] = []
        var inCode = false
        var language = ""

        func flush() {
            let joined = buffer.joined(separator: "\n")
            if inCode {
                out.append(Segment(id: out.count, kind: .code(language), text: joined))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Segment(id: out.count, kind: .prose, text: joined.trimmingCharacters(in: .newlines)))
            }
            buffer.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if inCode {
                    inCode = false
                } else {
                    inCode = true
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                buffer.append(line)
            }
        }
        flush()   // also handles a code block that's still streaming in
        return out
    }
}

@MainActor
struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    Pasteboard.copy(code)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

// MARK: - Attachments in sent messages

@MainActor
struct SentAttachments: View {
    let attachments: [Attachment]

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { a in
                        if let img = AttachmentStore.thumbnail(for: a) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: images.count == 1 ? 280 : 140,
                                       maxHeight: images.count == 1 ? 280 : 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { NSWorkspace.shared.open(a.url) }
                                .help("\(a.name) · click to open")
                        } else {
                            FileChip(attachment: a)
                        }
                    }
                }
            }
            ForEach(files) { a in
                FileChip(attachment: a)
            }
        }
    }
}

@MainActor
struct FileChip: View {
    let attachment: Attachment

    var body: some View {
        Button {
            NSWorkspace.shared.open(attachment.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(attachment.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Open \(attachment.name)")
    }
}
