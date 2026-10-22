import SwiftUI
import AppKit

/// The menu bar icon: a template version of the app icon, so it follows light/dark menu bars.
@MainActor
struct MenuBarLabel: View {
    var body: some View {
        if let img = MenuBarLabel.icon {
            Image(nsImage: img)
        } else {
            Image(systemName: "text.bubble")
        }
    }

    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

/// The panel that drops down from the menu bar icon: credit left, the latest reply, and a quick-ask box.
@MainActor
struct MenuBarView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var conversation: Conversation? {
        guard let id = store.selectedID else { return nil }
        return store.conversations.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude")
                    .font(.headline)
                Spacer()
                Text(ModelOption.find(conversation?.modelID ?? store.defaultModelID).name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CreditMeter()

            Divider()

            if store.apiKey.isEmpty {
                Text("Add your API key in the main window to start chatting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                lastExchange
                quickAsk
            }

            Divider()

            HStack {
                Button("Ask About Selection") { QuickPanelController.shared.askAboutSelection() }
                    .help("Same as ⌥Space")
                Button("Ask About Screen") { QuickPanelController.shared.askAboutScreen() }
                    .help("Same as ⌥⇧Space")
            }
            .buttonStyle(.borderless)
            .font(.callout)

            HStack {
                Button("Open Window") { showMainWindow() }
                Button("New Chat") {
                    store.newConversation()
                    focused = true
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Claude Chat")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            focused = true
            QuickPanelController.shared.openWindow = openWindow
        }
    }

    @ViewBuilder
    private var lastExchange: some View {
        let messages = conversation?.messages ?? []
        let lastUser = messages.last { $0.role == .user }
        let lastReply = messages.last.flatMap { $0.role == .assistant ? $0 : nil }

        if let u = lastUser {
            VStack(alignment: .leading, spacing: 8) {
                Text(u.text)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let r = lastReply {
                            if r.text.isEmpty && r.error == nil && store.isStreaming {
                                ProgressView().controlSize(.small)
                            } else {
                                MarkdownText(r.text)
                                    .font(.callout)
                            }
                            if let e = r.error {
                                Text(e)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if let c = r.cost {
                                Text("Cost \(Fmt.money(c))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        } else {
            Text("Ask anything. The full conversation is kept in the main window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var quickAsk: some View {
        HStack(spacing: 8) {
            TextField("Ask Claude…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
            if store.isStreaming {
                Button { store.stop() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
            }
        }
        .font(.title3)
    }

    private func send() {
        guard !store.isStreaming,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        draft = ""
        store.send(text)
    }

    private func showMainWindow() {
        // Bring an existing chat window forward, or open a new one.
        let existing = NSApp.windows.first { w in
            (w.identifier?.rawValue.hasPrefix("main") ?? false) && (w.isVisible || w.isMiniaturized)
        }
        if let w = existing {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
