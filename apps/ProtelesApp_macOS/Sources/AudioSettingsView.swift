import AppKit
import AVFoundation
import MudCore
import SwiftUI

/// Settings ▸ Audio (#10 + #9): the soundpack's master controls and the
/// text-to-speech preferences. Both edit their hand-editable Settings JSON
/// (`soundpack.json` / `speech.json`) and ask the session to reload the
/// owning native plugin, so changes land live — the same state the `spset`
/// and `tts` console commands mutate. Per-event sound tuning stays on the
/// command surface (`spset` — 69 events don't belong in a window).
struct AudioSettingsView: View {
    let session: SessionController

    @State private var soundpack = SoundpackConfig.load(from: try? SoundpackConfig.defaultURL())
    @State private var speech = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
    @State private var voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play event sounds", isOn: soundsEnabled)
                Text("Cues for tells, channels, quest events, level-ups and more — the Aardwolf "
                    + "soundpack. Your own files in Sounds/ override the built-in set; tune "
                    + "individual events with `spset`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Volume") {
                    Slider(value: globalVolume, in: 0...100, step: 5) { editing in
                        if !editing {
                            saveSoundpack()
                            reloadSoundpack()
                        }
                    }
                    .frame(maxWidth: 220)
                }
                Toggle("Use system alert when a sound file is missing", isOn: systemFallback)
                Button("Open Sounds Folder") {
                    if let url = try? ProtelesPaths.soundsDirectory() {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Speech") {
                Picker("Speak", selection: speechMode) {
                    Text("Nothing").tag(SpeechMode.off)
                    Text("Alerts and tells").tag(SpeechMode.alerts)
                    Text("Every line").tag(SpeechMode.everything)
                }
                Text("Text-to-speech for game output: 'every line' is the screen-reader "
                    + "experience (symbol art stripped, hidden lines never spoken); 'alerts' "
                    + "speaks tells and event-worthy lines only. Also: `tts` commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Rate: \(speech.wordsPerMinute) wpm") {
                    Slider(value: wordsPerMinute, in: 80...600, step: 10) { editing in
                        if !editing {
                            saveSpeech()
                            reloadSpeech()
                        }
                    }
                    .frame(maxWidth: 220)
                }
                Picker("Voice", selection: voiceSelection) {
                    Text("System default").tag("")
                    ForEach(Self.voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
                Toggle("Route through VoiceOver", isOn: voiceOverRouting)
                Text(voiceOverHint)
                    .font(.caption)
                    .foregroundStyle(voiceOverRunning && !speech.voiceOverRouting ? .orange : .secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            soundpack = SoundpackConfig.load(from: try? SoundpackConfig.defaultURL())
            speech = SpeechConfig.load(from: try? SpeechConfig.defaultURL())
            voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled
        }
    }

    /// VoiceOver routing speaks + brailles via the user's assistive
    /// settings (rate/voice are then VoiceOver's); warn about double-speak
    /// when VoiceOver is up but routing is off.
    private var voiceOverHint: String {
        if voiceOverRunning, !speech.voiceOverRouting {
            return "VoiceOver is running — routing through it avoids double-speak and reaches "
                + "braille displays. The app voice gives finer rate/voice control."
        }
        return "Announcements go through VoiceOver (speech + braille, its rate and voice). "
            + "Off: the app voice above, which works without VoiceOver."
    }

    // MARK: - Bindings (write-through to the Settings JSON + plugin reload)

    private var soundsEnabled: Binding<Bool> {
        Binding(
            get: { !soundpack.muted },
            set: { enabled in
                soundpack.muted = !enabled
                saveSoundpack()
                reloadSoundpack()
            }
        )
    }

    /// Sliders mutate only in-memory state per tick; the JSON write + plugin
    /// reload happen on release (`onEditingChanged false`) — a drag used to
    /// write soundpack.json 10–20×/second (2026-06 audit).
    private var globalVolume: Binding<Double> {
        Binding(
            get: { Double(soundpack.globalVolume) },
            set: { value in soundpack.globalVolume = Int(value) }
        )
    }

    private var systemFallback: Binding<Bool> {
        Binding(
            get: { soundpack.systemSoundFallback },
            set: { value in
                soundpack.systemSoundFallback = value
                saveSoundpack()
                reloadSoundpack()
            }
        )
    }

    private var speechMode: Binding<SpeechMode> {
        Binding(
            get: { speech.mode },
            set: { mode in
                speech.mode = mode
                saveSpeech()
                reloadSpeech()
            }
        )
    }

    private var wordsPerMinute: Binding<Double> {
        Binding(
            get: { Double(speech.wordsPerMinute) },
            set: { value in speech.wordsPerMinute = Int(value) }
        )
    }

    private var voiceSelection: Binding<String> {
        Binding(
            get: {
                guard let voice = speech.voice else { return "" }
                return SpeechController.resolveVoice(voice)?.identifier ?? ""
            },
            set: { identifier in
                speech.voice = identifier.isEmpty ? nil : identifier
                saveSpeech()
                reloadSpeech()
            }
        )
    }

    private static let voices = AVSpeechSynthesisVoice.speechVoices()
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }

    private var voiceOverRouting: Binding<Bool> {
        Binding(
            get: { speech.voiceOverRouting },
            set: { value in
                speech.voiceOverRouting = value
                saveSpeech()
                reloadSpeech()
            }
        )
    }

    private func saveSoundpack() {
        soundpack.save(to: try? SoundpackConfig.defaultURL())
    }

    private func saveSpeech() {
        speech.save(to: try? SpeechConfig.defaultURL())
    }

    /// Re-run the plugin's install() so it re-reads the file we just wrote.
    private func reloadSoundpack() {
        Task { await session.reloadNativePluginConfig(id: "com.proteles.soundpack") }
    }

    private func reloadSpeech() {
        Task { await session.reloadNativePluginConfig(id: "com.proteles.texttospeech") }
    }
}
