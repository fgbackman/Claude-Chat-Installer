import SwiftUI
import AppKit
import UserNotifications

// MARK: - Half-price batches

extension ChatStore {
    /// Batch requests cost 50% of the normal price.
    static let batchDiscount = 0.5

    private var batchFileURL: URL { Self.supportDirectory.appendingPathComponent("batches.json") }

    func loadBatchJobs() {
        guard let data = try? Data(contentsOf: batchFileURL),
              let saved = try? JSONDecoder().decode([BatchJob].self, from: data) else { return }
        batchJobs = saved
    }

    func saveBatchJobs() {
        if let data = try? JSONEncoder().encode(batchJobs) {
            try? data.write(to: batchFileURL, options: .atomic)
        }
    }

    func isQueued(_ messageID: UUID) -> Bool {
        submittingMessageIDs.contains(messageID)
            || batchJobs.contains { job in job.items.contains { $0.messageID == messageID } }
    }

    /// Batch params: the same as a normal request, minus streaming and automatic caching.
    func batchParams(_ request: MessageRequest) -> [String: Any] {
        var params = AnthropicClient.body(for: request)
        params.removeValue(forKey: "stream")
        params.removeValue(forKey: "cache_control")
        return params
    }

    /// Like send(), but queues the message at half price. The reply arrives later (usually within the hour).
    func sendLater(_ raw: String, includePending: Bool) {
        let text = raw.trimmed
        let attachments = includePending ? pendingAttachments : []
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming, !apiKey.isEmpty,
              let cid = selectedID, let i = index(of: cid) else { return }

        let conv = conversations[i]
        let model = ModelOption.find(conv.modelID)
        var history = conv.messages
        history.append(ChatMessage(role: .user, text: text, attachments: attachments))
        let params = batchParams(makeRequest(for: conv, model: model.id, history: history))

        if includePending { pendingAttachments = [] }
        attachmentError = nil
        conversations[i].messages = history
        retitle(i, text: text, attachments: attachments)
        conversations[i].updatedAt = Date()
        let reply = ChatMessage(role: .assistant, text: "", modelID: model.id)
        conversations[i].messages.append(reply)
        save()

        submitBatch(title: conversations[i].title,
                    entries: [BatchEntry(conversationID: cid, messageID: reply.id, modelID: model.id, params: params)])
    }

    /// One new chat per file, each with the same instruction, all in one half-price batch.
    @discardableResult
    func queueFiles(_ urls: [URL], instruction: String, modelID: String) -> Int {
        var entries: [BatchEntry] = []
        var problems: [String] = []
        for url in urls {
            do {
                let a = try AttachmentStore.make(from: url)
                var c = Conversation(modelID: modelID)
                c.title = "Batch: " + url.lastPathComponent
                let user = ChatMessage(role: .user, text: instruction.trimmed, attachments: [a])
                let reply = ChatMessage(role: .assistant, text: "", modelID: modelID)
                let params = batchParams(makeRequest(for: c, model: modelID, history: [user]))
                c.messages = [user, reply]
                conversations.append(c)
                entries.append(BatchEntry(conversationID: c.id, messageID: reply.id, modelID: modelID, params: params))
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        batchError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if !entries.isEmpty {
            save()
            submitBatch(title: "\(entries.count) file\(entries.count == 1 ? "" : "s"): \(instruction.trimmed.prefix(40))", entries: entries)
        }
        return entries.count
    }

    struct BatchEntry {
        let conversationID: UUID
        let messageID: UUID
        let modelID: String
        let params: [String: Any]
    }

    func submitBatch(title: String, entries: [BatchEntry]) {
        var requests: [[String: Any]] = []
        var items: [BatchItem] = []
        for (n, e) in entries.enumerated() {
            let customID = "req-\(n)"
            requests.append(["custom_id": customID, "params": e.params])
            items.append(BatchItem(customID: customID, conversationID: e.conversationID, messageID: e.messageID, modelID: e.modelID))
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["requests": requests]) else {
            markFailed(items, "Couldn't prepare the batch.")
            return
        }
        let ids = Set(items.map(\.messageID))
        submittingMessageIDs.formUnion(ids)
        Self.requestNotificationPermission()
        let key = apiKey

        Task {
            do {
                let batchID = try await AnthropicClient.createBatch(payload: payload, apiKey: key)
                self.batchJobs.append(BatchJob(id: batchID, items: items, title: title))
                self.saveBatchJobs()
                self.submittingMessageIDs.subtract(ids)
                self.startBatchPolling()
            } catch {
                self.submittingMessageIDs.subtract(ids)
                self.markFailed(items, "Couldn't queue the batch: \(error.localizedDescription)")
            }
        }
    }

    private func markFailed(_ items: [BatchItem], _ message: String) {
        for it in items {
            update(it.conversationID, it.messageID) { $0.error = message }
        }
        save()
    }

    /// Checks waiting batches every minute while the app is open.
    func startBatchPolling() {
        guard batchPollTask == nil, !batchJobs.isEmpty else { return }
        batchPollTask = Task {
            while !Task.isCancelled && !self.batchJobs.isEmpty {
                await self.checkBatches()
                if self.batchJobs.isEmpty { break }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            self.batchPollTask = nil
        }
    }

    func checkBatches() async {
        let key = apiKey
        guard !key.isEmpty else { return }
        for job in batchJobs {
            do {
                let status = try await AnthropicClient.batchStatus(job.id, apiKey: key)
                guard status.status == "ended", let url = status.resultsURL else { continue }
                let results = try await AnthropicClient.batchResults(url, apiKey: key)
                applyResults(results, to: job)
                batchError = nil
            } catch {
                batchError = "Couldn't check a batch: \(error.localizedDescription)"
            }
        }
    }

    private func applyResults(_ results: [BatchResult], to job: BatchJob) {
        var ready = 0
        for item in job.items {
            let model = ModelOption.find(item.modelID)
            guard let r = results.first(where: { $0.customID == item.customID }) else {
                update(item.conversationID, item.messageID) { $0.error = "No result came back for this request." }
                continue
            }
            if let text = r.text {
                let usage = r.usage ?? Usage()
                let cost = model.cost(usage) * Self.batchDiscount
                update(item.conversationID, item.messageID) { m in
                    m.text = text
                    m.usage = usage
                    m.cost = cost
                    m.error = nil
                }
                addSpend(cost)
                ready += 1
            } else {
                let message = r.error ?? "This request failed."
                update(item.conversationID, item.messageID) { $0.error = message }
            }
        }
        batchJobs.removeAll { $0.id == job.id }
        saveBatchJobs()
        save()
        Self.notify(title: "Half-price batch finished",
                    body: "\(ready) of \(job.items.count) replies ready · \(job.title)")
    }

    // MARK: Notifications (only when running as a real .app bundle)

    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

// MARK: - Batch window

@MainActor
struct BatchView: View {
    @Environment(ChatStore.self) private var store
    @State private var instruction = "Summarize this file in five bullet points."
    @State private var files: [URL] = []
    @State private var modelID = "claude-sonnet-5-5"
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Half-price batch")
                .font(.title2.weight(.semibold))
            Text("Each file gets its own chat with the same instruction. Batches cost 50% less and usually finish within an hour; you'll get a notification. For a single message, use the send button's menu → Send Later at Half Price.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Instruction")
                .font(.headline)
            TextEditor(text: $instruction)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

            HStack {
                Text("Model")
                Picker("Model", selection: $modelID) {
                    ForEach(ModelOption.all) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Add Files…") {
                    files += FilePicker.choose(message: "Choose the files to process")
                }
                Button("Clear") { files = [] }
                    .disabled(files.isEmpty)
            }

            List {
                if files.isEmpty {
                    Text("No files yet. Photos, PDFs, Word and text files all work.")
                        .foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "doc")
                }
            }
            .frame(minHeight: 120)

            HStack {
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Queue \(files.count) at Half Price") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(files.isEmpty || instruction.trimmed.isEmpty || store.apiKey.isEmpty)
            }

            Divider()

            HStack {
                Text("Waiting batches")
                    .font(.headline)
                Spacer()
                Button("Check Now") {
                    Task { await store.checkBatches() }
                }
                .disabled(store.batchJobs.isEmpty)
            }
            if store.batchJobs.isEmpty {
                Text("None right now.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.batchJobs) { job in
                    HStack {
                        Image(systemName: "hourglass")
                        Text(job.title)
                            .lineLimit(1)
                        Spacer()
                        Text("\(job.items.count) request\(job.items.count == 1 ? "" : "s") · sent \(job.createdAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if let e = store.batchError {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 600)
    }

    private func submit() {
        let n = store.queueFiles(files, instruction: instruction, modelID: modelID)
        note = n > 0 ? "Queued \(n) file\(n == 1 ? "" : "s"). Replies will appear in new chats in the sidebar." : nil
        files = []
    }
}

/// Menu command that opens the batch window.
@MainActor
struct OpenBatchButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Half-Price Batch…") { openWindow(id: "batch") }
            .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}
