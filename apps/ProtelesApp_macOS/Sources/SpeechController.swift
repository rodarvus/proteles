import AppKit
import AVFoundation
import MudCore
import os

/// The app's TTS renderer (#9): consumes ``SessionController/speechRequests``
/// and speaks them through one of two backends:
///
/// - **App voice** (default): `AVSpeechSynthesizer` — full control of rate,
///   voice, queue, and interrupt. Works without VoiceOver; most VI MUDders
///   run a dedicated app voice.
/// - **VoiceOver routing** (`speech.json: voiceOverRouting`): accessibility
///   announcements, which speak *and* braille via the user's assistive
///   settings. Rate/voice are then VoiceOver's to own — our settings don't
///   apply — and queue control is the priority field only.
///
/// Double-speak guard: when the app voice is used while VoiceOver is
/// running, a once-per-launch os_log warning fires (the Audio settings pane
/// shows the visible hint).
@MainActor
final class SpeechController: NSObject, AVSpeechSynthesizerDelegate {
    private static let log = Logger(subsystem: "com.proteles", category: "Speech")

    /// When this many utterances are waiting, speech has fallen hopelessly
    /// behind the game — flush and catch up to the newest line instead of
    /// narrating the past (the live report: "still babbling a minute after I
    /// turned it off"). Screen readers behave the same way under flooding.
    private static let queueCatchUpThreshold = 10

    private let synthesizer = AVSpeechSynthesizer()
    private var config = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
    private var warnedAboutVoiceOver = false
    /// Utterances handed to the synthesizer and not yet finished/cancelled,
    /// tracked by identity so a flush can't be undercounted by the cancelled
    /// batch's late delegate callbacks.
    private var pendingUtterances: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func handle(_ request: SpeechRequest) {
        switch request {
        case .speak(let text, let interrupt):
            speak(text, interrupt: interrupt)
        case .stop:
            flush()
        case .reloadConfig:
            config = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
        }
    }

    /// Stop the current utterance AND everything queued behind it.
    private func flush() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances.removeAll()
    }

    private func speak(_ text: String, interrupt: Bool) {
        // The package's `tts focus`: drop utterances while Proteles isn't
        // the active app (off by default).
        if config.quietWhenUnfocused, !NSApp.isActive { return }
        if config.voiceOverRouting {
            announceViaVoiceOver(text, interrupt: interrupt)
            return
        }
        if NSWorkspace.shared.isVoiceOverEnabled, !warnedAboutVoiceOver {
            warnedAboutVoiceOver = true
            Self.log.warning("app voice speaking while VoiceOver runs — voiceOverRouting avoids double-speak")
        }
        if interrupt, synthesizer.isSpeaking {
            flush()
        } else if pendingUtterances.count >= Self.queueCatchUpThreshold {
            // Too far behind reality: drop the backlog, speak the newest.
            flush()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate(forWordsPerMinute: config.wordsPerMinute)
        if let voice = Self.resolveVoice(config.voice) {
            utterance.voice = voice
        }
        pendingUtterances.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.pendingUtterances.remove(id)
        }
    }

    nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.pendingUtterances.remove(id)
        }
    }

    /// VoiceOver announcement: speaks + brailles per the user's AT settings.
    /// `interrupt` maps to announcement priority (high cuts in; medium queues
    /// per VoiceOver's own policy).
    private func announceViaVoiceOver(_ text: String, interrupt: Bool) {
        guard let element = NSApp.mainWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: interrupt
                    ? NSAccessibilityPriorityLevel.high.rawValue
                    : NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    /// Words-per-minute → `AVSpeechUtterance.rate` (0…1). The platform
    /// default rate (0.5) speaks ≈175 wpm, and the scale is roughly linear
    /// below 1.0 — an approximation, but it makes `tts rate 350` mean
    /// "about twice as fast", which is what users tune by ear.
    static func rate(forWordsPerMinute wordsPerMinute: Int) -> Float {
        let normalized = Float(wordsPerMinute) / 175.0 * Float(AVSpeechUtteranceDefaultSpeechRate)
        return min(max(normalized, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Resolve a configured voice by identifier, then by case-insensitive
    /// name match; nil (or no match) means the system default voice.
    static func resolveVoice(_ configured: String?) -> AVSpeechSynthesisVoice? {
        guard let configured, !configured.isEmpty else { return nil }
        if let exact = AVSpeechSynthesisVoice(identifier: configured) { return exact }
        let lowered = configured.lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.name.lowercased() == lowered
        } ?? AVSpeechSynthesisVoice.speechVoices().first {
            $0.name.lowercased().contains(lowered)
        }
    }
}
