import SwiftUI
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Observation

// MARK: - Global hotkeys (Carbon; no special permission needed to register them)

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4348), id: id)   // 'CLCH'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

/// Carbon callback. A file-scope (nonisolated) function, so it converts cleanly to a C function pointer.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard err == OSStatus(noErr) else { return err }
    let id = hotKeyID.id
    Task { @MainActor in HotKeyCenter.shared.fire(id) }
    return OSStatus(noErr)
}

// MARK: - Grabbing the selection from other apps

@MainActor
enum SelectionGrabber {
    /// Copying and pasting into other apps needs Accessibility permission.
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends ⌘C to the front app and returns the copied text, then puts the old clipboard text back.
    static func copySelection() async -> String? {
        guard trusted else {
            askForTrust()
            return nil
        }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        if let saved {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
        return text
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum ScreenGrab {
    /// Runs the system screenshot tool in interactive mode: drag an area, or press Space to pick a window.
    static func capture(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            p.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try p.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - The floating panel

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class QuickPanelController {
    static let shared = QuickPanelController()

    private(set) weak var store: ChatStore?
    let model = QuickAskModel()
    var openWindow: OpenWindowAction?
    private var panel: QuickPanel?

    func attach(_ store: ChatStore) {
        self.store = store
        updateHotKeys()
    }

    func updateHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        guard let store, store.hotkeysEnabled else { return }
        // ⌥Space: ask about the selected text.  ⌥⇧Space: ask about an area of the screen.
        HotKeyCenter.shared.register(id: 1, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
            QuickPanelController.shared.askAboutSelection()
        }
        HotKeyCenter.shared.register(id: 2, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)) {
            QuickPanelController.shared.askAboutScreen()
        }
    }

    func askAboutSelection() {
        let front = NSWorkspace.shared.frontmostApplication
        let isMe = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        model.reset(previousApp: isMe ? nil : front)
        Task {
            if !isMe, let text = await SelectionGrabber.copySelection() {
                self.model.source = text
            }
            if !SelectionGrabber.trusted {
                self.model.notice = "To grab selected text from other apps, allow Claude Chat under Accessibility in System Settings, then try again."
            }
            self.show()
        }
    }

    func askAboutScreen() {
        model.reset(previousApp: nil)
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("claudechat-\(UUID().uuidString).png")
            _ = await ScreenGrab.capture(to: url)
            guard FileManager.default.fileExists(atPath: url.path) else { return }   // cancelled
            do {
                self.model.attachment = try AttachmentStore.make(from: url)
            } catch {
                self.model.error = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: url)
            self.show()
        }
    }

    func show() {
        guard let store else { return }
        if panel == nil {
            let p = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickAskView(model: model).environment(store))
            panel = p
        }
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            var origin = NSPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y - panel.frame.height - 16)
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - panel.frame.height - 8)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Brings the main chat window forward, opening one if none is open.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let existing = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }
        if let w = existing {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else if let open = openWindow {
            open(id: "main")
        }
    }
}

struct QuickAction: Identifiable {
    let id: String
    let instruction: String
}

@MainActor
@Observable
final class QuickAskModel {
    var source = ""
    var attachment: Attachment?
    var question = ""
    var output = ""
    var isRunning = false
    var cost: Double = 0
    var error: String?
    var notice: String?
    var lastInstruction = ""
    @ObservationIgnored var previousApp: NSRunningApplication?
    @ObservationIgnored private var task: Task<Void, Never>?

    static let system = "You are a quick helper inside a Mac utility. Be concise. When asked to fix, rewrite or translate, reply with only the resulting text, with no preamble or quotes."

    static let actions: [QuickAction] = [
        QuickAction(id: "Explain", instruction: "Explain this clearly and briefly."),
        QuickAction(id: "Fix", instruction: "Fix the spelling and grammar. Reply with only the corrected text."),
        QuickAction(id: "Rewrite", instruction: "Rewrite this to be clearer and more natural, keeping the meaning. Reply with only the rewritten text."),
        QuickAction(id: "Summarize", instruction: "Summarize this in a few short bullet points."),
        QuickAction(id: "Translate", instruction: "Translate this into English, or into Spanish if it's already English. Reply with only the translation."),
    ]

    var hasInput: Bool { !source.trimmed.isEmpty || attachment != nil }

    func reset(previousApp: NSRunningApplication?) {
        task?.cancel()
        source = ""
        attachment = nil
        question = ""
        output = ""
        isRunning = false
        cost = 0
        error = nil
        notice = nil
        lastInstruction = ""
        self.previousApp = previousApp
    }

    func run(_ instruction: String, store: ChatStore) {
        guard !store.apiKey.isEmpty else {
            error = "Add your API key in Claude Chat first."
            return
        }
        task?.cancel()
        output = ""
        error = nil
        cost = 0
        isRunning = true
        lastInstruction = instruction

        var blocks: [[String: Any]] = []
        if let a = attachment { blocks.append(contentsOf: AttachmentStore.blocks(for: a)) }
        let src = source.trimmed
        if !src.isEmpty { blocks.append(["type": "text", "text": "<text>\n\(src)\n</text>"]) }
        blocks.append(["type": "text", "text": instruction])
        let message: [String: Any] = ["role": "user", "content": blocks]

        let model = ModelOption.find(store.quickModelID)
        let request = MessageRequest(model: model.id, system: Self.system, messages: [message],
                                     maxTokens: 4_000, effort: .low, showThinking: false, useCache: false)
        guard let body = try? JSONSerialization.data(withJSONObject: AnthropicClient.body(for: request)) else {
            isRunning = false
            return
        }
        let key = store.apiKey
        task = Task {
            var usage = Usage()
            do {
                for try await event in AnthropicClient.stream(body: body, apiKey: key) {
                    switch event {
                    case .text(let t):
                        self.output += t
                    case .usage(let u):
                        usage = u
                        self.cost = model.cost(u)
                    default:
                        break
                    }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled { self.error = error.localizedDescription }
            }
            store.addSpend(model.cost(usage))
            self.isRunning = false
        }
    }

    func replaceSelection() {
        guard !output.isEmpty else { return }
        Pasteboard.copy(output)
        let app = previousApp
        QuickPanelController.shared.close()
        Task {
            app?.activate(options: [])
            try? await Task.sleep(nanoseconds: 250_000_000)
            if SelectionGrabber.trusted {
                SelectionGrabber.postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            }
        }
    }

    /// Saves this exchange as a normal chat and opens it.
    func openInChat(_ store: ChatStore) {
        let src = source.trimmed
        let parts = [src, lastInstruction].filter { !$0.isEmpty }
        let text = parts.joined(separator: "\n\n")
        var c = Conversation(modelID: store.quickModelID)
        c.title = ChatStore.makeTitle(lastInstruction.isEmpty ? (text.isEmpty ? "Quick question" : text) : lastInstruction)
        var messages = [ChatMessage(role: .user, text: text, attachments: attachment.map { [$0] } ?? [])]
        if !output.isEmpty {
            var reply = ChatMessage(role: .assistant, text: output, modelID: store.quickModelID)
            reply.cost = cost
            messages.append(reply)
        }
        c.messages = messages
        store.conversations.append(c)
        store.selectedID = c.id
        store.save()
        QuickPanelController.shared.close()
        QuickPanelController.shared.showMainWindow()
    }
}

@MainActor
struct QuickAskView: View {
    @Environment(ChatStore.self) private var store
    @Bindable var model: QuickAskModel
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text("Ask Claude")
                    .font(.headline)
                Spacer()
                Text(ModelOption.find(store.quickModelID).name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    QuickPanelController.shared.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }

            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") { SelectionGrabber.openAccessibilitySettings() }
                        .font(.caption)
                }
            }

            if let a = model.attachment, let img = AttachmentStore.thumbnail(for: a) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.source)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if model.source.isEmpty {
                        Text("Selected text appears here. You can also type or paste.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }

            HStack(spacing: 6) {
                ForEach(QuickAskModel.actions) { action in
                    Button(action.id) { model.run(action.instruction, store: store) }
                        .disabled(model.isRunning || !model.hasInput)
                }
            }

            HStack {
                TextField("Or ask anything about it…", text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .focused($questionFocused)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .disabled(model.isRunning || model.question.trimmed.isEmpty)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let e = model.error {
                        Text(e)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if model.output.isEmpty && model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    MarkdownText(model.output)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 110)

            HStack {
                if model.cost > 0 {
                    Text(Fmt.money(model.cost))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Copy") { Pasteboard.copy(model.output) }
                    .disabled(model.output.isEmpty)
                if model.previousApp != nil && !model.source.isEmpty {
                    Button("Replace Selection") { model.replaceSelection() }
                        .disabled(model.output.isEmpty || model.isRunning)
                }
                Button("Open in Chat") { model.openInChat(store) }
                    .disabled(!model.hasInput && model.output.isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { questionFocused = true }
    }

    private func ask() {
        let q = model.question.trimmed
        guard !q.isEmpty, !model.isRunning else { return }
        model.run(q, store: store)
    }
}
