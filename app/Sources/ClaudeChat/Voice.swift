import Foundation
import AVFoundation
import Speech
import Observation

/// On-device dictation into the message box (Apple's Speech framework; audio stays on the Mac when supported).
@MainActor
@Observable
final class Dictation {
    static let shared = Dictation()

    var isRecording = false
    var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onText: ((String) -> Void)?

    /// `onText` receives the full transcript so far, each time it changes.
    func toggle(onText: @escaping (String) -> Void) {
        if isRecording { stop() } else { start(onText: onText) }
    }

    func start(onText: @escaping (String) -> Void) {
        error = nil
        self.onText = onText
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    Dictation.shared.error = "Allow Speech Recognition for Claude Chat in System Settings → Privacy & Security."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        if granted {
                            Dictation.shared.begin()
                        } else {
                            Dictation.shared.error = "Allow Microphone access for Claude Chat in System Settings → Privacy & Security."
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn't available right now."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            error = "No microphone found. Connect one, or pick an input in System Settings → Sound."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(for: req))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        request = req
        isRecording = true
        task = recognizer.recognitionTask(with: req, resultHandler: Self.resultHandler())
    }

    // Built outside the main actor: these run on audio / recognition threads.
    nonisolated private static func tapBlock(for req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func resultHandler() -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, err in
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || err != nil
            Task { @MainActor in
                Dictation.shared.handle(text: text, finished: finished)
            }
        }
    }

    private func handle(text: String?, finished: Bool) {
        if let text { onText?(text) }
        if finished { stop() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}

/// Reads replies aloud with the Mac's built-in voices (free, offline).
@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    var isSpeaking: Bool { synth.isSpeaking }

    func toggle(_ text: String) {
        if synth.isSpeaking { stop() } else { speak(text) }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: Self.plain(text))
        utterance.voice = Self.bestVoice()
        synth.speak(utterance)
    }

    /// The best-quality installed voice for the Mac's language (Premium or Enhanced if downloaded).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Markdown to speakable text: drops code blocks and formatting symbols.
    static func plain(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inCode { out.append("(code omitted)") }
                inCode.toggle()
                continue
            }
            if inCode { continue }
            var l = line
            for symbol in ["**", "__", "`", "#"] {
                l = l.replacingOccurrences(of: symbol, with: "")
            }
            l = l.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)) }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }
}
