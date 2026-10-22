import SwiftUI

enum SendMode {
    case normal, duel, later

    var verb: String {
        switch self {
        case .normal: return "Send"
        case .duel: return "Start Duel"
        case .later: return "Queue at Half Price"
        }
    }
}

@MainActor
struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let conversationID: UUID

    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var estimate: Int?
    @State private var confirmMode: SendMode?
    @State private var confirmMessage = ""
    @State private var showConfirm = false
    @State private var dictationBase = ""
    @FocusState private var composerFocused: Bool

    private var dictation: Dictation { Dictation.shared }

    private var conversation: Conversation? {
        store.conversation(conversationID)
    }

    private var model: ModelOption {
        ModelOption.find(conversation?.modelID ?? store.defaultModelID)
    }

    private var currentEffort: Effort {
        store.effectiveEffort(for: conversationID)
    }

    var body: some View {
        @Bindable var bstore = store
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if conversation?.messages.isEmpty ?? true {
                            EmptyChatHint(model: model, effort: currentEffort, presetName: conversation?.presetName)
                        }
                        ForEach(conversation?.messages ?? []) { m in
                            MessageRow(message: m, conversationID: conversationID)
                                .id(m.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation?.messages.last?.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: conversation?.messages.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            composer
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            store.addAttachments(files)
            composerFocused = true
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .navigationTitle(conversation?.title ?? "Claude")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(item: $bstore.duel) { _ in
            DuelView()
                .environment(store)
                .interactiveDismissDisabled()
        }
        .confirmationDialog("Send this message?", isPresented: $showConfirm, presenting: confirmMode) { mode in
            Button("\(mode.verb) Anyway") { perform(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(confirmMessage)
        }
        .task(id: previewKey) {
            await refreshEstimate()
        }
        .onAppear {
            composerFocused = true
            QuickPanelController.shared.openWindow = openWindow
        }
        .onDisappear {
            if dictation.isRecording { dictation.stop() }
        }
    }

    private var subtitle: String {
        var parts = [model.name, "effort \(currentEffort.label.lowercased())"]
        if let p = conversation?.presetName { parts.insert(p, at: 0) }
        parts.append("this chat \(Fmt.money(conversation?.totalCost ?? 0))")
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(ModelOption.all) { m in
                    Button {
                        store.setModel(m.id, for: conversationID)
                    } label: {
                        if m.id == model.id {
                            Label("\(m.name): \(m.blurb)", systemImage: "checkmark")
                        } else {
                            Text("\(m.name): \(m.blurb)")
                        }
                    }
                }
            } label: {
                Text(model.name)
            }
            .fixedSize()
            .help(model.blurb)

            Menu {
                ForEach(Effort.allCases) { e in
                    Button {
                        store.setEffort(e, for: conversationID)
                    } label: {
                        if e == currentEffort {
                            Label(e.label, systemImage: "checkmark")
                        } else {
                            Text(e.label)
                        }
                    }
                }
            } label: {
                Text("Effort: \(currentEffort.label)")
            }
            .fixedSize()
            .help("Effort for this chat: lower means less thinking, so cheaper and faster replies")

            Button {
                openWindow(id: "batch")
            } label: {
                Label("Half-Price Batch", systemImage: "tray.full")
            }
            .help("Queue files or questions at half price (⌘⇧B)")
        }
    }

    // MARK: Composer

    private var canSend: Bool {
        !draft.trimmed.isEmpty || !store.pendingAttachments.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = store.attachmentError ?? dictation.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(err)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        store.attachmentError = nil
                        dictation.error = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .foregroundStyle(.red)
            }

            if !store.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pendingAttachments) { a in
                            PendingAttachmentChip(attachment: a) {
                                store.removePending(a.id)
                            }
                        }
                    }
                }
            }

            composerRow
            costLine
        }
        .padding(12)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .background(hiddenShortcuts)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                Button("Choose Files…") { store.chooseAttachments() }
                Button("Paste Image or File from Clipboard  ⌘⇧V") { store.attachFromClipboard() }
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.bottom, 9)
            .help("Attach pictures, PDFs or text files (or drag them here)")

            Button {
                toggleDictation()
            } label: {
                Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 18))
                    .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 9)
            .help(dictation.isRecording ? "Stop dictation" : "Dictate (on-device speech recognition)")

            TextField(dictation.isRecording ? "Listening…" : "Message Claude…  (Return to send, ⌥Return for a new line)",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($composerFocused)
                .onSubmit { attempt(.normal) }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dictation.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary)))

            if store.isStreaming {
                Button {
                    if store.duel != nil { store.discardDuel() } else { store.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            } else {
                HStack(spacing: 2) {
                    Button {
                        attempt(.normal)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!canSend)
                    .help("Send")

                    Menu {
                        Button("Send  (Return)") { attempt(.normal) }
                        Button("Duel: Haiku vs Sonnet vs Opus  (⌘⇧Return)") { attempt(.duel) }
                        Button("Send Later at Half Price  (⌥⌘Return)") { attempt(.later) }
                        Divider()
                        Button("Half-Price Batch of Files…") { openWindow(id: "batch") }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!canSend)
                    .help("More ways to send")
                }
                .padding(.bottom, 2)
            }
        }
    }

    /// Invisible buttons that carry the keyboard shortcuts for the other send modes.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { attempt(.duel) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { attempt(.later) }
                .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var costLine: some View {
        let today = store.dailyLimit > 0
            ? "Today \(Fmt.money(store.spentToday)) of \(Fmt.money(store.dailyLimit))"
            : "Today \(Fmt.money(store.spentToday))"
        HStack(spacing: 6) {
            if let n = estimate, canSend {
                Text("≈ \(Fmt.tokens(n)) tokens in · about \(Fmt.money(model.inputCost(n))) to send, plus the reply")
                if store.useCache && (conversation?.messages.count ?? 0) > 1 {
                    Text("(less with caching)")
                }
            }
            Spacer()
            Text(today)
                .foregroundStyle(store.dailyLimit > 0 && store.spentToday >= store.dailyLimit ? Color.red : Color.secondary)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    // MARK: Cost preview (free token counting)

    private var previewKey: String {
        "\(draft)|\(store.pendingAttachments.map(\.storedFile).joined())|\(model.id)|\(conversation?.messages.count ?? 0)"
    }

    private func refreshEstimate() async {
        guard canSend else {
            estimate = nil
            return
        }
        try? await Task.sleep(nanoseconds: 700_000_000)   // wait for a pause in typing
        if Task.isCancelled { return }
        let n = await store.countTokens(cid: conversationID, draft: draft)
        if !Task.isCancelled { estimate = n }
    }

    private func estimatedCost(_ mode: SendMode) -> Double {
        guard let n = estimate else { return 0 }
        switch mode {
        case .normal: return model.inputCost(n)
        case .later: return model.inputCost(n) * ChatStore.batchDiscount
        case .duel: return ModelOption.duelIDs.reduce(0.0) { $0 + ModelOption.find($1).inputCost(n) }
        }
    }

    // MARK: Sending

    private func attempt(_ mode: SendMode) {
        guard !store.isStreaming, canSend else { return }
        if let warning = store.spendWarning(estimatedCost: estimatedCost(mode)) {
            confirmMessage = warning
            confirmMode = mode
            showConfirm = true
        } else {
            perform(mode)
        }
    }

    private func perform(_ mode: SendMode) {
        guard !store.isStreaming, canSend else { return }
        if dictation.isRecording { dictation.stop() }
        let text = draft
        draft = ""
        estimate = nil
        switch mode {
        case .normal: store.send(text, includePending: true)
        case .duel: store.startDuel(text, includePending: true)
        case .later: store.sendLater(text, includePending: true)
        }
    }

    private func toggleDictation() {
        if !dictation.isRecording {
            dictationBase = draft.isEmpty ? "" : draft + " "
        }
        let base = dictationBase
        dictation.toggle { transcript in
            draft = base + transcript
        }
    }
}

@MainActor
struct PendingAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let img = AttachmentStore.thumbnail(for: attachment) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: attachment.symbol)
                    .font(.system(size: 20))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

@MainActor
struct EmptyChatHint: View {
    let model: ModelOption
    let effort: Effort
    var presetName: String? = nil

    var body: some View {
        // A typical short exchange: ~1,000 tokens in, ~800 out (thinking included).
        let typical = model.cost(Usage(inputTokens: 1_000, outputTokens: 800))
        let heading: String = presetName.map { name in "\(name) · \(model.name)" } ?? "New chat with \(model.name)"
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(heading)
                .font(.title3.weight(.semibold))
            Text(model.blurb)
                .foregroundStyle(.secondary)
            Text("A short back-and-forth costs roughly \(Fmt.money(typical)) per reply. Longer chats cost more, because the whole conversation is sent each time.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text("Tip: the ⌄ next to Send runs a duel between Haiku, Sonnet and Opus, or queues the message at half price.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
