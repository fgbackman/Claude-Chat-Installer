import SwiftUI
import AppKit

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PresetsSettings()
                .tabItem { Label("Presets", systemImage: "square.stack") }
            VoiceShortcutSettings()
                .tabItem { Label("Voice & Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 660)
    }
}

// MARK: - General

@MainActor
struct GeneralSettings: View {
    @Environment(ChatStore.self) private var store
    @State private var keyDraft = ""
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("API key") {
                SecureField("Paste a new key (sk-ant-…)", text: $keyDraft)
                HStack {
                    Button("Save Key") {
                        store.setAPIKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    if store.apiKey.isEmpty {
                        Text("No key saved").foregroundStyle(.secondary)
                    } else {
                        Text("Saved key ends in …\(String(store.apiKey.suffix(4)))")
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { store.setAPIKey("") }
                    }
                }
            }

            Section {
                TextField("Starting credit ($)", value: $store.startingCredit, format: .number)
                LabeledContent("Spent so far (estimate)", value: Fmt.money(store.totalSpent))
                LabeledContent("Spent today", value: Fmt.money(store.spentToday))
                LabeledContent("Left", value: Fmt.money(store.remainingCredit))
                Button("Reset Spent to $0…") { confirmReset = true }
            } header: {
                Text("Credit tracking")
            } footer: {
                Text("Worked out from the token counts the API reports and the published per-token prices. The Claude Console's usage and billing pages are the real record.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Daily limit ($, 0 = none)", value: $store.dailyLimit, format: .number)
                TextField("Ask before sending anything over ($, 0 = never)", value: $store.confirmAbove, format: .number)
            } header: {
                Text("Budget")
            } footer: {
                Text("Over the daily limit, or when a message's estimated cost is above the threshold, the app asks before sending. Estimates come from Anthropic's free token counter.")
                    .foregroundStyle(.secondary)
            }

            Section("Replies") {
                Picker("Default model for new chats", selection: $store.defaultModelID) {
                    ForEach(ModelOption.all) { m in
                        Text("\(m.name): \(m.blurb)").tag(m.id)
                    }
                }
                Picker("Default effort for new chats", selection: $store.effort) {
                    ForEach(Effort.allCases) { e in
                        Text(e.label).tag(e)
                    }
                }
                Stepper("Max reply length: \(store.maxTokens.formatted()) tokens",
                        value: $store.maxTokens, in: 1_000...64_000, step: 1_000)
                Toggle("Show Claude's reasoning (summarized)", isOn: $store.showThinking)
                Toggle("Prompt caching (makes long chats much cheaper)", isOn: $store.useCache)
            }

            Section {
                TextEditor(text: $store.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 80)
            } header: {
                Text("System prompt")
            } footer: {
                Text("Optional standing instructions sent with every message, e.g. \"Call me Fred. Keep answers short.\" A preset's instructions are added after these.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the spending counter to $0?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                store.totalSpent = 0
                store.spendByDay = [:]
            }
        }
    }
}

// MARK: - Presets

@MainActor
struct PresetsSettings: View {
    @Environment(ChatStore.self) private var store
    @State private var editing: Preset?

    var body: some View {
        Form {
            Section {
                ForEach(store.presets) { p in
                    HStack {
                        Image(systemName: p.symbol)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text("\(ModelOption.find(p.modelID).name) · effort \(p.effort.label.lowercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = p }
                        Button(role: .destructive) {
                            store.presets.removeAll { $0.id == p.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Start a chat from a preset with the New Chat button's menu in the sidebar. Each preset sets the model, effort and extra instructions for that chat.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Preset") {
                    editing = Preset(name: "New preset", symbol: "star", modelID: store.defaultModelID,
                                     effort: .medium, systemPrompt: "")
                }
                Spacer()
                Button("Restore Defaults") { store.presets = Preset.defaults }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { p in
            PresetEditor(preset: p)
                .environment(store)
        }
    }
}

@MainActor
struct PresetEditor: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Preset

    static let symbols = ["star", "bolt", "lightbulb", "pencil.line", "chevron.left.forwardslash.chevron.right",
                          "book", "globe", "cart", "wineglass", "car", "music.note", "camera", "hammer", "heart"]

    init(preset: Preset) {
        _draft = State(initialValue: preset)
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            Picker("Icon", selection: $draft.symbol) {
                ForEach(Self.symbols, id: \.self) { s in
                    Label(s, systemImage: s).labelStyle(.iconOnly).tag(s)
                }
            }
            Picker("Model", selection: $draft.modelID) {
                ForEach(ModelOption.all) { m in
                    Text(m.name).tag(m.id)
                }
            }
            Picker("Effort", selection: $draft.effort) {
                ForEach(Effort.allCases) { e in
                    Text(e.label).tag(e)
                }
            }
            Section("Instructions for chats started from this preset") {
                TextEditor(text: $draft.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 120)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.upsertPreset(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmed.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
    }
}

// MARK: - Voice & shortcuts

@MainActor
struct VoiceShortcutSettings: View {
    @Environment(ChatStore.self) private var store
    @State private var trusted = SelectionGrabber.trusted

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Global shortcuts", isOn: $store.hotkeysEnabled)
                LabeledContent("⌥ Space", value: "Ask about the selected text in any app")
                LabeledContent("⌥ ⇧ Space", value: "Ask about an area of the screen")
                Picker("Model for quick questions", selection: $store.quickModelID) {
                    ForEach(ModelOption.all) { m in
                        Text("\(m.name): \(m.blurb)").tag(m.id)
                    }
                }
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                    Text(trusted ? "Accessibility allowed: selected text can be grabbed and replaced."
                                 : "Allow Accessibility so ⌥ Space can grab and replace selected text.")
                    Spacer()
                    if !trusted {
                        Button("Allow…") {
                            SelectionGrabber.askForTrust()
                            SelectionGrabber.openAccessibilitySettings()
                        }
                    }
                    Button("Recheck") { trusted = SelectionGrabber.trusted }
                }
                .font(.callout)
            } header: {
                Text("Ask from anywhere")
            } footer: {
                Text("Select text in any app and press ⌥ Space for a floating panel with Explain, Fix, Rewrite, Summarize and Translate, plus Replace Selection. ⌥ ⇧ Space lets you drag over part of the screen (or press Space to pick a window) and ask about it; macOS will ask once for Screen Recording permission. After installing a new build, macOS may ask for these permissions again.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Read replies aloud automatically", isOn: $store.readAloud)
                LabeledContent("Voice", value: Speaker.bestVoice()?.name ?? "System default")
                Button("Test Voice") {
                    Speaker.shared.speak("Hi Fred. This is how replies will sound.")
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Use the microphone button next to the message box to dictate; recognition runs on your Mac when it's supported. Every reply also has a speaker button. For a more natural voice, download a Premium or Enhanced voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
