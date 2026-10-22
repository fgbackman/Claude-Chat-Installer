import SwiftUI
import AppKit

// MARK: - Model duel: one question, three models, side by side

extension ChatStore {
    func startDuel(_ raw: String, includePending: Bool) {
        let text = raw.trimmed
        let attachments = includePending ? pendingAttachments : []
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming, !apiKey.isEmpty,
              let cid = selectedID, let conv = conversation(cid) else { return }

        var history = conv.messages
        history.append(ChatMessage(role: .user, text: text, attachments: attachments))

        var bodies: [Data] = []
        for id in ModelOption.duelIDs {
            guard let body = encodedBody(makeRequest(for: conv, model: id, history: history)) else { return }
            bodies.append(body)
        }

        if includePending { pendingAttachments = [] }
        attachmentError = nil
        let state = DuelState(conversationID: cid, prompt: text, attachments: attachments,
                              entries: ModelOption.duelIDs.map { DuelEntry(modelID: $0) })
        duel = state
        isStreaming = true

        let key = apiKey
        let duelID = state.id
        var tasks: [Task<Void, Never>] = []
        for n in bodies.indices {
            let body = bodies[n]
            let model = ModelOption.find(ModelOption.duelIDs[n])
            let task = Task {
                var usage = Usage()
                do {
                    for try await event in AnthropicClient.stream(body: body, apiKey: key) {
                        switch event {
                        case .text(let t):
                            self.updateDuel(duelID, n) { $0.text += t }
                        case .usage(let u):
                            usage = u
                            self.updateDuel(duelID, n) { $0.usage = u; $0.cost = model.cost(u) }
                        case .thinking:
                            break
                        case .stop(let reason):
                            if reason == "max_tokens" {
                                self.updateDuel(duelID, n) { $0.error = "Hit the max reply length." }
                            }
                        }
                    }
                } catch {
                    let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                    let message = error.localizedDescription
                    if !cancelled { self.updateDuel(duelID, n) { $0.error = message } }
                }
                self.addSpend(model.cost(usage))
                self.updateDuel(duelID, n) { $0.done = true }
                if let d = self.duel, d.id == duelID, d.allDone {
                    self.isStreaming = false
                }
            }
            tasks.append(task)
        }
        duelTasks = tasks
    }

    private func updateDuel(_ duelID: UUID, _ n: Int, _ change: (inout DuelEntry) -> Void) {
        guard var d = duel, d.id == duelID, d.entries.indices.contains(n) else { return }
        change(&d.entries[n])
        duel = d
    }

    /// Keeps the chosen answer in the chat and switches the chat to that model.
    func pickDuelWinner(_ modelID: String) {
        guard let d = duel, let i = index(of: d.conversationID),
              let entry = d.entries.first(where: { $0.modelID == modelID }) else { return }
        for t in duelTasks { t.cancel() }
        duelTasks = []

        conversations[i].messages.append(ChatMessage(role: .user, text: d.prompt, attachments: d.attachments))
        var reply = ChatMessage(role: .assistant, text: entry.text, modelID: modelID)
        reply.usage = entry.usage
        reply.cost = d.total          // the whole duel, so the chat total stays accurate
        reply.error = entry.error
        conversations[i].messages.append(reply)
        conversations[i].modelID = modelID
        retitle(i, text: d.prompt, attachments: d.attachments)
        conversations[i].updatedAt = Date()

        duel = nil
        isStreaming = false
        save()
    }

    /// Closes the duel without keeping an answer. Attachments go back to the composer.
    func discardDuel() {
        for t in duelTasks { t.cancel() }
        duelTasks = []
        if let d = duel {
            pendingAttachments = d.attachments + pendingAttachments
        }
        duel = nil
        isStreaming = false
    }
}

// MARK: - Branches

extension ChatStore {
    /// Copies a chat up to a message into a new branch (shown under the original in the sidebar) and opens it.
    @discardableResult
    func branch(from cid: UUID, at messageID: UUID, including: Bool) -> UUID? {
        guard let src = conversation(cid),
              let j = src.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        var c = Conversation(modelID: src.modelID)
        let base = src.title.hasPrefix("↳ ") ? String(src.title.dropFirst(2)) : src.title
        c.title = "↳ " + base
        c.parentID = cid
        c.presetName = src.presetName
        c.systemOverride = src.systemOverride
        c.effortOverride = src.effortOverride
        c.messages = src.messages.prefix(including ? j + 1 : j).map { m in
            var copy = m
            copy.id = UUID()
            return copy
        }
        conversations.append(c)
        selectedID = c.id
        save()
        return c.id
    }

    /// Starts a branch just before a user message and sends an edited version of it.
    func editAndResend(_ cid: UUID, messageID: UUID, newText: String) {
        guard !isStreaming,
              let m = conversation(cid)?.messages.first(where: { $0.id == messageID }),
              m.role == .user,
              branch(from: cid, at: messageID, including: false) != nil else { return }
        send(newText, attachments: m.attachments)
    }

    /// Asks again for a reply, on a new branch, so the original answer is kept.
    func retry(_ cid: UUID, replyID: UUID) {
        guard let msgs = conversation(cid)?.messages,
              let j = msgs.firstIndex(where: { $0.id == replyID }),
              let user = msgs[..<j].last(where: { $0.role == .user }) else { return }
        editAndResend(cid, messageID: user.id, newText: user.text)
    }
}

// MARK: - Duel window

@MainActor
struct DuelView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = store.duel {
                HStack(alignment: .firstTextBaseline) {
                    Text("Model duel")
                        .font(.title3.weight(.semibold))
                    Text("Total so far \(Fmt.money(d.total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard All") { store.discardDuel() }
                }
                Text(d.prompt.isEmpty ? "(attachments only)" : d.prompt)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(d.entries) { entry in
                        DuelColumn(entry: entry)
                    }
                }
                Text("Pick the answer to keep. The chat switches to that model, and the cost of all three is counted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(minWidth: 960, minHeight: 560)
    }
}

@MainActor
struct DuelColumn: View {
    @Environment(ChatStore.self) private var store
    let entry: DuelEntry

    var body: some View {
        let model = ModelOption.find(entry.modelID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.name)
                    .font(.headline)
                Spacer()
                if !entry.done {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(entry.done
                 ? "\(Fmt.tokens(entry.usage?.outputTokens ?? 0)) tokens out · \(Fmt.money(entry.cost))"
                 : "Writing… \(Fmt.money(entry.cost))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let e = entry.error {
                        Text(e)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    MarkdownText(entry.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                store.pickDuelWinner(entry.modelID)
            } label: {
                Text("Keep \(model.name)'s Answer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(entry.text.isEmpty)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

// MARK: - Edit & resend sheet

@MainActor
struct EditResendSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    let message: ChatMessage
    @State private var text: String

    init(conversationID: UUID, message: ChatMessage) {
        self.conversationID = conversationID
        self.message = message
        _text = State(initialValue: message.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit and resend")
                .font(.headline)
            Text("This starts a new branch from this point. The original chat stays as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send as Branch") {
                    let edited = text
                    dismiss()
                    store.editAndResend(conversationID, messageID: message.id, newText: edited)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(store.isStreaming || (text.trimmed.isEmpty && message.attachments.isEmpty))
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
