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
final class SpeechController {
    private static let log = Logger(subsystem: "com.proteles", category: "Speech")

    private let synthesizer = AVSpeechSynthesizer()
    private var config = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
    private var warnedAboutVoiceOver = false

    func handle(_ request: SpeechRequest) {
        switch request {
        case .speak(let text, let interrupt):
            speak(text, interrupt: interrupt)
        case .stop:
            synthesizer.stopSpeaking(at: .immediate)
        case .reloadConfig:
            config = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
        }
    }

    private func speak(_ text: String, interrupt: Bool) {
        if config.voiceOverRouting {
            announceViaVoiceOver(text, interrupt: interrupt)
            return
        }
        if NSWorkspace.shared.isVoiceOverEnabled, !warnedAboutVoiceOver {
            warnedAboutVoiceOver = true
            Self.log.warning("app voice speaking while VoiceOver runs — voiceOverRouting avoids double-speak")
        }
        if interrupt, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Self.rate(forWordsPerMinute: config.wordsPerMinute)
        if let voice = Self.resolveVoice(config.voice) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
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
