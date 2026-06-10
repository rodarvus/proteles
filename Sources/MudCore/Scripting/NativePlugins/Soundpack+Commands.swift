import Foundation

/// The soundpack's `sp*` command surface (its own file for the length
/// budget) — console-faithful to the reference's aliases: `spset` (list /
/// show / set), `sptog`, `spvol`, `spmute`, `spdebug`, `sphelp`. The
/// reference's `spsetvol` opened a GUI input box; `spset <event> volume N`
/// covers it. `spallow`/`spdeny`/`savesound` are gone with the remote-sound
/// download.
public extension Soundpack {
    mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").map(String.init)
        switch parts.first?.lowercased() {
        case "spset": return handleSpset(Array(parts.dropFirst()))
        case "sptog": return handleSptog(Array(parts.dropFirst()))
        case "spvol": return handleSpvol(Array(parts.dropFirst()))
        case "spmute" where parts.count == 1: return handleSpmute()
        case "spdebug" where parts.count == 1: return handleSpdebug()
        case "sphelp" where parts.count == 1: return handleSphelp()
        default: return nil
        }
    }

    // MARK: - spset

    private mutating func handleSpset(_ args: [String]) -> [ScriptEffect]? {
        switch args.count {
        case 0:
            listEvents()
        case 1:
            showEvent(args[0].lowercased())
        case 3:
            setEvent(args[0].lowercased(), setting: args[1].lowercased(), value: args[2])
        default:
            [Self.errorNote("Usage: spset [event] [volume|panning|wav] [value] — see sphelp.")]
        }
    }

    /// The reference's `listEvents`: every event with a toggle hyperlink,
    /// its volume (colour-coded), description, and any custom wav.
    private func listEvents() -> [ScriptEffect] {
        var effects: [ScriptEffect] = [
            Self.note("Sound Pack Settings"),
            .colourNote([NoteSegment(
                text: Self.pad("Event", 22) + Self.pad("Volume", 8) + Self
                    .pad("Description", 42) + "Custom Wav",
                foreground: "#20B2AA"
            )]),
            .colourNote([NoteSegment(
                text: String(repeating: "-", count: 90), foreground: "#4682B4"
            )])
        ]
        for event in SoundEventClassifier.orderedEventNames {
            let volume = config.volume(for: event)
            let volumeColor = volume > 70 ? "#32CD32" : (volume > 30 ? "#FFFF00" : "#FF0000")
            var segments = [
                NoteSegment(
                    text: Self.pad(event, 22),
                    foreground: "#20B2AA",
                    link: LineLink(actionString: "sptog \(event)", hint: "Toggle event: \(event)")
                ),
                NoteSegment(
                    text: Self.pad("\(volume)%", 8),
                    foreground: volumeColor,
                    link: LineLink(actionString: "spset \(event)", hint: "Show settings: \(event)")
                ),
                NoteSegment(
                    text: Self.pad(SoundEventClassifier.defaults[event]?.description ?? "", 42),
                    foreground: "#4682B4"
                )
            ]
            if let custom = config.events[event]?.file {
                segments.append(NoteSegment(text: custom, foreground: "#3CB371"))
            }
            effects.append(.colourNote(segments))
        }
        return effects
    }

    private func showEvent(_ event: String) -> [ScriptEffect] {
        guard let defaults = SoundEventClassifier.defaults[event] else {
            return [Self.errorNote("Invalid event: \(event)")]
        }
        var effects = [Self.note(
            "Event: \(event)\nVolume: \(config.volume(for: event)), "
                + "Panning: \(config.pan(for: event)) Desc: \(defaults.description)"
        )]
        if let custom = config.events[event]?.file {
            effects.append(Self.note("Custom wav file set to: \(custom)"))
        }
        return effects
    }

    private mutating func setEvent(_ event: String, setting: String, value: String) -> [ScriptEffect] {
        guard SoundEventClassifier.defaults[event] != nil else {
            return [Self.errorNote("Invalid event: \(event)")]
        }
        switch setting {
        case "volume":
            guard let volume = Int(value), (0...100).contains(volume) else {
                return [Self.errorNote("Invalid value \"\(value)\" for volume — use 0-100.")]
            }
            config.updateOverride(for: event) { $0.volume = volume == 100 ? nil : volume }
            saveConfig()
            return [Self.note("\(event) volume setting has been set to: \(volume)"), confirmationCue()]
        case "panning":
            guard let pan = Int(value), (-100...100).contains(pan) else {
                return [Self.errorNote("Invalid value \"\(value)\" for panning — use -100 to 100.")]
            }
            config.updateOverride(for: event) { $0.pan = pan == 0 ? nil : pan }
            saveConfig()
            return [Self.note("\(event) panning setting has been set to: \(pan)"), confirmationCue()]
        case "wav":
            if value.lowercased() == "default" {
                config.updateOverride(for: event) { $0.file = nil }
                saveConfig()
                return [Self.note("\(event) wav setting has been reset to default."), confirmationCue()]
            }
            config.updateOverride(for: event) { $0.file = value }
            saveConfig()
            var effects = [Self.note("\(event) wav setting has been set to: \(value)")]
            if Self.isMissingFromSoundsFolder(value) {
                effects.append(Self.note(
                    "(\(value) isn't in your Sounds folder yet — a fallback cue plays until it is.)"
                ))
            }
            effects.append(confirmationCue())
            return effects
        default:
            return [Self.errorNote("Unknown setting \"\(setting)\" — use volume, panning or wav.")]
        }
    }

    // MARK: - sptog / spvol / spmute / spdebug / sphelp

    private mutating func handleSptog(_ args: [String]) -> [ScriptEffect]? {
        guard args.count == 1 else {
            return [Self.errorNote("Usage: sptog <event>|all")]
        }
        let target = args[0].lowercased()
        if target == "all" {
            // Reference behaviour: every event flips independently.
            for event in SoundEventClassifier.orderedEventNames {
                let current = config.volume(for: event)
                config.updateOverride(for: event) { $0.volume = current == 0 ? nil : 0 }
            }
            saveConfig()
            return [Self.note("All events have been toggled."), confirmationCue()]
        }
        guard SoundEventClassifier.defaults[target] != nil else {
            return [Self.errorNote("Invalid event. Type \"spset\" to see a list of events.")]
        }
        if config.volume(for: target) == 0 {
            config.updateOverride(for: target) { $0.volume = nil }
            saveConfig()
            return [
                Self.note("Event \"\(target)\" has been enabled. Volume reset to 100."),
                confirmationCue()
            ]
        }
        config.updateOverride(for: target) { $0.volume = 0 }
        saveConfig()
        return [Self.note("Event \"\(target)\" has been disabled."), confirmationCue()]
    }

    private mutating func handleSpvol(_ args: [String]) -> [ScriptEffect]? {
        guard let value = args.first else {
            return [Self.note("Global volume is currently set to \(config.globalVolume)")]
        }
        guard let volume = Int(value), (0...100).contains(volume) else {
            return [Self.errorNote("Global volume requires a valid number between 0 and 100")]
        }
        config.globalVolume = volume
        saveConfig()
        return [Self.note("Global volume has been set to \(volume)"), confirmationCue()]
    }

    private mutating func handleSpmute() -> [ScriptEffect] {
        config.muted.toggle()
        saveConfig()
        let state = config.muted ? "Disabled" : "Enabled"
        let color = config.muted ? "#FF0000" : "#32CD32"
        return [
            .colourNote([
                NoteSegment(text: "[", foreground: "#4682B4"),
                NoteSegment(text: "Soundpack", foreground: "#3CB371"),
                NoteSegment(text: "] Soundpack has been: ", foreground: "#4682B4"),
                NoteSegment(text: state, foreground: color)
            ]),
            confirmationCue()
        ]
    }

    private mutating func handleSpdebug() -> [ScriptEffect] {
        config.debug.toggle()
        saveConfig()
        return [Self.note("Debug has been \(config.debug ? "enabled" : "disabled").")]
    }

    private func handleSphelp() -> [ScriptEffect] {
        var effects = [Self.note("SoundPack for Aardwolf — native port (after Pwar's v1.1.2)")]
        for command in help.commands {
            effects.append(.colourNote([
                NoteSegment(text: "  " + Self.pad(command.syntax, 34), foreground: "#20B2AA"),
                NoteSegment(text: command.summary, foreground: "#4682B4")
            ]))
        }
        effects.append(Self.note(
            "Sounds load from ~/Documents/Proteles/Sounds/ (yours), then the bundled set. "
                + "Remote !!SOUND(url) downloads are not supported."
        ))
        return effects
    }

    /// Whether `name` is absent from the user's Sounds folder (used only for
    /// a courtesy note — a missing file still resolves via the fallbacks).
    private static func isMissingFromSoundsFolder(_ name: String) -> Bool {
        guard let sounds = try? ProtelesPaths.soundsDirectory() else { return false }
        return !FileManager.default.fileExists(atPath: sounds.appendingPathComponent(name).path)
    }

    /// Right-pad to a column width (the reference's `padRight`).
    internal static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}
