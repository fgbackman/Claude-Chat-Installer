import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Shows the app in the Dock with its icon, even when launched as a bare binary (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar after the last chat window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no windows open brings a chat window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

@main
struct ClaudeChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup("Claude", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newConversation() }
                    .keyboardShortcut("n")
                Menu("New Chat from Preset") {
                    ForEach(store.presets) { p in
                        Button(p.name) { store.newConversation(preset: p) }
                    }
                }
                Divider()
                Button("Attach Files…") { store.chooseAttachments() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste as Attachment") { store.attachFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Tools") {
                OpenBatchButton()
                Divider()
                Button("Ask About Selected Text  ⌥Space") {
                    QuickPanelController.shared.askAboutSelection()
                }
                Button("Ask About Screen Area  ⌥⇧Space") {
                    QuickPanelController.shared.askAboutScreen()
                }
                Divider()
                Button("Stop Reading Aloud") { Speaker.shared.stop() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
            }
        }

        Window("Half-Price Batch", id: "batch") {
            BatchView()
                .environment(store)
        }
        .defaultSize(width: 620, height: 680)

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
