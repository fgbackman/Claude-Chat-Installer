import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ChatStore {
    var conversations: [Conversation] = []
    var selectedID: UUID?
    var isStreaming = false
    var apiKey: String = ""
    var pendingAttachments: [Attachment] = []
    var attachmentError: String?

    // Model duel (Duel.swift)
    var duel: DuelState?
    @ObservationIgnored var duelTasks: [Task<Void, Never>] = []

    // Half-price batches (Batch.swift)
    var batchJobs: [BatchJob] = []
    var submittingMessageIDs: Set<UUID> = []
    var batchError: String?
    @ObservationIgnored var batchPollTask: Task<Void, Never>?

    // Settings, persisted in UserDefaults
    var defaultModelID: String { didSet { defaults.set(defaultModelID, forKey: "defaultModelID") } }
    var effort: Effort { didSet { defaults.set(effort.rawValue, forKey: "effort") } }
    var showThinking: Bool { didSet { defaults.set(showThinking, forKey: "showThinking") } }
    var useCache: Bool { didSet { defaults.set(useCache, forKey: "useCache") } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: "systemPrompt") } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: "maxTokens") } }
    var startingCredit: Double { didSet { defaults.set(startingCredit, forKey: "startingCredit") } }
    var totalSpent: Double { didSet { defaults.set(totalSpent, forKey: "totalSpent") } }
    var dailyLimit: Double { didSet { defaults.set(dailyLimit, forKey: "dailyLimit") } }
    var confirmAbove: Double { didSet { defaults.set(confirmAbove, forKey: "confirmAbove") } }
    var spendByDay: [String: Double] { didSet { defaults.set(spendByDay, forKey: "spendByDay") } }
    var readAloud: Bool { didSet { defaults.set(readAloud, forKey: "readAloud") } }
    var quickModelID: String { didSet { defaults.set(quickModelID, forKey: "quickModelID") } }
    var hotkeysEnabled: Bool {
        didSet {
            defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled")
            QuickPanelController.shared.updateHotKeys()
        }
    }
    var presets: [Preset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "presets") }
        }
    }

    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored private var streamTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        defaultModelID = d.string(forKey: "defaultModelID") ?? ModelOption.fallback.id
        effort = Effort(rawValue: d.string(forKey: "effort") ?? "") ?? .medium
        showThinking = d.object(forKey: "showThinking") as? Bool ?? false
        useCache = d.object(forKey: "useCache") as? Bool ?? true
        systemPrompt = d.string(forKey: "systemPrompt") ?? ""
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 16_000
        startingCredit = d.object(forKey: "startingCredit") as? Double ?? 100
        totalSpent = d.double(forKey: "totalSpent")
        dailyLimit = d.object(forKey: "dailyLimit") as? Double ?? 0
        confirmAbove = d.object(forKey: "confirmAbove") as? Double ?? 0.25
        spendByDay = d.dictionary(forKey: "spendByDay") as? [String: Double] ?? [:]
        readAloud = d.object(forKey: "readAloud") as? Bool ?? false
        quickModelID = d.string(forKey: "quickModelID") ?? "claude-haiku-5-5"
        hotkeysEnabled = d.object(forKey: "hotkeysEnabled") as? Bool ?? true
        if let data = d.data(forKey: "presets"), let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        } else {
            presets = Preset.defaults
        }
        apiKey = Keychain.load() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""

        load()
        loadBatchJobs()
        if conversations.isEmpty {
            newConversation()
        } else {
            selectedID = sortedConversations.first?.id
        }

        Task { @MainActor in
            QuickPanelController.shared.attach(self)
            self.startBatchPolling()
        }
    }

    // MARK: Derived

    var remainingCredit: Double { startingCredit - totalSpent }
    var sortedConversations: [Conversation] { conversations.sorted { $0.updatedAt > $1.updatedAt } }

    func index(of id: UUID) -> Int? {
        conversations.firstIndex { $0.id == id }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func effectiveEffort(for cid: UUID) -> Effort {
        conversation(cid)?.effortOverride ?? effort
    }

    /// Conversations as a tree: branches appear under the chat they came from.
    var sidebarRows: [SidebarRow] {
        let ids = Set(conversations.map(\.id))
        var children: [UUID: [Conversation]] = [:]
        var roots: [Conversation] = []
        for c in conversations {
            if let p = c.parentID, ids.contains(p) {
                children[p, default: []].append(c)
            } else {
                roots.append(c)
            }
        }
        var out: [SidebarRow] = []
        func walk(_ c: Conversation, _ depth: Int) {
            out.append(SidebarRow(conversation: c, depth: depth))
            let kids = (children[c.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            for k in kids { walk(k, depth + 1) }
        }
        for r in roots.sorted(by: { $0.updatedAt > $1.updatedAt }) { walk(r, 0) }
        return out
    }

    // MARK: Spending

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    var spentToday: Double { spendByDay[Self.dayKey()] ?? 0 }

    func addSpend(_ amount: Double) {
        guard amount > 0 else { return }
        totalSpent += amount
        spendByDay[Self.dayKey(), default: 0] += amount
    }

    /// A reason to ask before sending, or nil if it's fine to go ahead.
    func spendWarning(estimatedCost: Double) -> String? {
        if dailyLimit > 0 && spentToday >= dailyLimit {
            return "You've spent \(Fmt.money(spentToday)) today, which is at or over your daily limit of \(Fmt.money(dailyLimit))."
        }
        if confirmAbove > 0 && estimatedCost >= confirmAbove {
            return "Sending this will cost about \(Fmt.money(estimatedCost)) before the reply."
        }
        return nil
    }

    // MARK: Conversations

    func newConversation() {
        if let id = selectedID, let i = index(of: id), conversations[i].messages.isEmpty, conversations[i].presetName == nil {
            conversations[i].modelID = defaultModelID
            return   // reuse the empty chat that's already open
        }
        let c = Conversation(modelID: defaultModelID)
        conversations.append(c)
        selectedID = c.id
        save()
    }

    func newConversation(preset: Preset) {
        var c = Conversation(modelID: preset.modelID)
        c.presetName = preset.name
        c.systemOverride = preset.systemPrompt.trimmed.isEmpty ? nil : preset.systemPrompt
        c.effortOverride = preset.effort
        conversations.append(c)
        selectedID = c.id
        save()
    }

    func upsertPreset(_ p: Preset) {
        if let i = presets.firstIndex(where: { $0.id == p.id }) {
            presets[i] = p
        } else {
            presets.append(p)
        }
    }

    func delete(_ id: UUID) {
        if isStreaming && selectedID == id { stop() }
        guard let i = index(of: id) else { return }
        let removed = conversations[i]
        // Branches of the deleted chat move up to its parent.
        for j in conversations.indices where conversations[j].parentID == id {
            conversations[j].parentID = removed.parentID
        }
        conversations.remove(at: i)
        // Branches share attachment files, so only delete files no other chat uses.
        var stillUsed = Set<String>()
        for c in conversations {
            for m in c.messages {
                for a in m.attachments { stillUsed.insert(a.storedFile) }
            }
        }
        for m in removed.messages {
            for a in m.attachments where !stillUsed.contains(a.storedFile) {
                AttachmentStore.delete(a)
            }
        }
        if selectedID == id { selectedID = sortedConversations.first?.id }
        if conversations.isEmpty { newConversation() }
        save()
    }

    func setModel(_ modelID: String, for cid: UUID) {
        guard let i = index(of: cid) else { return }
        conversations[i].modelID = modelID
        if conversations[i].presetName == nil { defaultModelID = modelID }
        save()
    }

    func setEffort(_ e: Effort, for cid: UUID) {
        guard let i = index(of: cid) else { return }
        conversations[i].effortOverride = e
        save()
    }

    func setAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { Keychain.delete() } else { Keychain.save(k) }
        apiKey = k
    }

    // MARK: Attachments waiting to be sent

    func addAttachments(_ urls: [URL]) {
        attachmentError = nil
        var problems: [String] = []
        for url in urls {
            do {
                pendingAttachments.append(try AttachmentStore.make(from: url))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { attachmentError = problems.joined(separator: "\n") }
    }

    func addImage(_ image: NSImage, name: String = "Pasted image") {
        attachmentError = nil
        do {
            pendingAttachments.append(try AttachmentStore.make(fromImage: image, name: name))
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    /// ⌘⇧V: attach copied files or a copied image (e.g. a screenshot taken with ⌃⇧⌘4).
    func attachFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addAttachments(urls)
        } else if let image = NSImage(pasteboard: pb) {
            addImage(image)
        } else {
            attachmentError = "There's no image or file on the clipboard."
        }
    }

    func chooseAttachments() {
        let urls = FilePicker.choose(message: "Choose pictures, PDFs or text files to send to Claude")
        if !urls.isEmpty { addAttachments(urls) }
    }

    func removePending(_ id: UUID) {
        if let a = pendingAttachments.first(where: { $0.id == id }) { AttachmentStore.delete(a) }
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: Building requests

    /// The request for a conversation's history, using its preset's instructions and effort if it has them.
    func makeRequest(for conv: Conversation, model: String, history: [ChatMessage]) -> MessageRequest {
        let system = [systemPrompt.trimmed, (conv.systemOverride ?? "").trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return MessageRequest(
            model: model,
            system: system,
            messages: Self.apiMessages(history),
            maxTokens: maxTokens,
            effort: conv.effortOverride ?? effort,
            showThinking: showThinking,
            useCache: useCache
        )
    }

    /// JSON body for a streaming request, or nil (with an error shown) if it's too big to send.
    func encodedBody(_ request: MessageRequest) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: AnthropicClient.body(for: request)) else {
            attachmentError = "Couldn't prepare the message."
            return nil
        }
        guard body.count <= AnthropicClient.maxRequestBytes else {
            attachmentError = "This chat plus its attachments is over the API's 32 MB request limit. Remove an attachment or start a new chat (⌘N)."
            return nil
        }
        return body
    }

    // MARK: Sending

    /// Sends a message. `includePending` sends the attachments waiting in the composer;
    /// `attachments` adds others (used when resending an edited message on a branch).
    func send(_ raw: String, includePending: Bool = false, attachments extra: [Attachment] = []) {
        let text = raw.trimmed
        let attachments = (includePending ? pendingAttachments : []) + extra
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming, !apiKey.isEmpty,
              let cid = selectedID, let i = index(of: cid) else { return }

        let conv = conversations[i]
        let model = ModelOption.find(conv.modelID)
        var history = conv.messages
        history.append(ChatMessage(role: .user, text: text, attachments: attachments))
        guard let body = encodedBody(makeRequest(for: conv, model: model.id, history: history)) else { return }

        if includePending { pendingAttachments = [] }
        attachmentError = nil
        conversations[i].messages = history
        retitle(i, text: text, attachments: attachments)
        conversations[i].updatedAt = Date()

        let reply = ChatMessage(role: .assistant, text: "", modelID: model.id)
        let mid = reply.id
        conversations[i].messages.append(reply)
        streamReply(body: body, model: model, cid: cid, mid: mid)
    }

    func retitle(_ i: Int, text: String, attachments: [Attachment]) {
        if conversations[i].title == "New chat" {
            conversations[i].title = Self.makeTitle(text.isEmpty ? (attachments.first?.name ?? "Attachment") : text)
        }
    }

    private func streamReply(body: Data, model: ModelOption, cid: UUID, mid: UUID) {
        let key = apiKey
        isStreaming = true
        streamTask = Task {
            var usage = Usage()
            do {
                for try await event in AnthropicClient.stream(body: body, apiKey: key) {
                    switch event {
                    case .text(let t):
                        self.update(cid, mid) { $0.text += t }
                    case .thinking(let t):
                        self.update(cid, mid) { $0.thinking += t }
                    case .usage(let u):
                        usage = u
                        self.update(cid, mid) { $0.usage = u; $0.cost = model.cost(u) }
                    case .stop(let reason):
                        if reason == "max_tokens" {
                            self.update(cid, mid) { $0.error = "Reply hit the max length limit. Raise it in Settings (⌘,) if you need longer answers." }
                        } else if reason == "refusal" {
                            self.update(cid, mid) { $0.error = "Claude declined to continue this reply." }
                        }
                    }
                }
                if Task.isCancelled {
                    self.update(cid, mid) { if $0.text.isEmpty { $0.error = "Stopped." } }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                let message = error.localizedDescription
                self.update(cid, mid) { m in
                    if !cancelled {
                        m.error = message
                    } else if m.text.isEmpty {
                        m.error = "Stopped."
                    }
                }
            }
            self.addSpend(model.cost(usage))
            self.isStreaming = false
            self.streamTask = nil
            self.save()
            if self.readAloud, let reply = self.conversation(cid)?.messages.first(where: { $0.id == mid }), !reply.text.isEmpty {
                Speaker.shared.speak(reply.text)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    func update(_ cid: UUID, _ mid: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = index(of: cid),
              let j = conversations[i].messages.firstIndex(where: { $0.id == mid }) else { return }
        change(&conversations[i].messages[j])
    }

    // MARK: Token counting (free) for the cost preview

    func countTokens(cid: UUID, draft: String) async -> Int? {
        guard !apiKey.isEmpty, let conv = conversation(cid) else { return nil }
        let text = draft.trimmed
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return nil }
        var history = conv.messages
        history.append(ChatMessage(role: .user, text: text, attachments: pendingAttachments))
        let req = makeRequest(for: conv, model: conv.modelID, history: history)
        var body: [String: Any] = ["model": req.model, "messages": req.messages]
        if !req.system.isEmpty { body["system"] = req.system }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? await AnthropicClient.countTokens(body: data, apiKey: apiKey)
    }

    // MARK: API message format

    /// Turns the visible chat into alternating user/assistant API messages with content blocks.
    /// Attachments go before the text of their message, which is how Claude reads them best.
    static func apiMessages(_ msgs: [ChatMessage]) -> [[String: Any]] {
        var turns: [(role: Role, blocks: [[String: Any]])] = []
        for m in msgs {
            var blocks: [[String: Any]] = []
            if m.role == .user {
                for a in m.attachments { blocks.append(contentsOf: AttachmentStore.blocks(for: a)) }
            }
            if !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(["type": "text", "text": m.text])
            }
            if blocks.isEmpty { continue }
            if let last = turns.last, last.role == m.role {
                turns[turns.count - 1].blocks.append(contentsOf: blocks)
            } else {
                turns.append((role: m.role, blocks: blocks))
            }
        }
        while turns.first?.role == .assistant { turns.removeFirst() }
        return turns.map { ["role": $0.role.rawValue, "content": $0.blocks] }
    }

    static func makeTitle(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }

    // MARK: Persistence (~/Library/Application Support/ClaudeChat/)

    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var fileURL: URL { Self.supportDirectory.appendingPathComponent("conversations.json") }

    func save() {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ClaudeChat: save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = saved
    }
}

@MainActor
enum FilePicker {
    static func choose(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
