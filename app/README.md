# Claude Chat 2.0

A native SwiftUI Mac app for chatting with Claude through the Claude API, using your own API key and credit. Dock icon, menu bar panel, and a floating "ask from anywhere" panel.

## Features

**Chat**
- Streaming replies, Stop (⌘.), saved history, API key in the Keychain
- Model per chat: Sonnet 5.5, Opus 5.5, Haiku 5.5, Fable 5.1; effort per chat
- Attachments: photos (incl. HEIC), PDFs, text/code/Word/RTF. Paperclip, drag and drop, ⌘O, or ⌘⇧V to paste a screenshot
- Prompt caching on by default, so long chats are much cheaper

**Model duel** — the ⌄ next to Send → Duel (⌘⇧Return). The same question goes to Haiku, Sonnet and Opus at once; the answers stream side by side with their costs. Keep the best one and the chat switches to that model.

**Cost preview and budget** — while you type, the app asks Anthropic's free token counter what the message will cost and shows it under the box. Set a daily limit and an "ask before sending over $X" threshold in Settings → General.

**Half price "later" mode** — ⌄ → Send Later at Half Price (⌥⌘Return) queues one message through the Batch API at 50% off. Tools → Half-Price Batch (⌘⇧B) runs one instruction over many files, each in its own chat. Results usually arrive within the hour, with a notification. The app checks every minute while it's open.

**Ask from anywhere** — select text in any app and press ⌥Space: a floating panel offers Explain, Fix, Rewrite, Summarize, Translate or your own question, then Copy, Replace Selection or Open in Chat. ⌥⇧Space lets you drag over part of the screen (or press Space to pick a window) and ask about it. Needs Accessibility permission (for copying/pasting the selection) and Screen Recording (asked once). Toggle and pick the model in Settings → Voice & Shortcuts.

**Branches** — under any of your messages: ✎ edits and resends it as a new branch; the branch icon copies the chat up to that point. Under replies: ↻ tries again on a branch, keeping the original. Branches appear nested under their parent in the sidebar.

**Voice** — the microphone button dictates into the message box (on-device recognition where supported). Every reply has a speaker button; Settings can read every reply aloud. ⌥⌘. stops reading.

**Presets** — New Chat's menu (sidebar) starts a chat with a saved model, effort and instructions: Quick answers (Haiku, low), Swift code review (Opus, high), Writing editor, Explain it simply. Edit them in Settings → Presets.

**Menu bar** — credit left, the latest reply, a quick-ask box, and buttons for the ask-anywhere panel.

## Install

Run the installer in the "Claude Chat Installer" folder:

```bash
bash ~/Developer/"Claude Chat Installer"/install.sh
```

It builds the app (Xcode or Command Line Tools needed, macOS 14+), installs it, pins it to the Dock and launches it. Running it again updates the app and keeps your chats and key. If the build fails, send install-log.txt to Claude.

## Prices built in (per million tokens, Anthropic's pricing page, Oct 2026)

| Model      | Input  | Output | Cache read | Batch (50% off) |
|------------|--------|--------|------------|-----------------|
| Haiku 5.5  | $0.10  | $0.50  | $0.01      | $0.05 / $0.25   |
| Sonnet 5.5 | $2     | $10    | $0.10      | $1 / $5         |
| Opus 5.5   | $4     | $20    | $0.20      | $2 / $10        |
| Fable 5.1  | $10    | $50    | $0.25      | $5 / $25        |

Haiku 5.5 costs more for prompts over 100k tokens ($0.50 / $2.50). Thinking tokens bill as output, so effort is the main cost dial. Token counting is free. Edit `ModelOption.all` in Models.swift if prices change.

## Notes

- The credit meter is an estimate; the Claude Console is the real record.
- The app is signed ad hoc, so after each rebuild macOS may ask again for Keychain, Accessibility, Microphone or Screen Recording access.
- Chats, attachments and batch jobs live in ~/Library/Application Support/ClaudeChat. Nothing is sent anywhere except api.anthropic.com.
