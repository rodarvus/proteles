import Foundation

/// The soundpack's `sp*` command surface (its own file for the length
/// budget) — console-faithful to the reference's aliases: `spset` (list /
/// show / set), `sptog`, `spvol`, `spmute`, `spdebug`, `sphelp` — plus what
/// the cue map adds (S1 step 2): `spset … wav add|remove` for variants and
/// `spcat` for category volumes. The
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
        case "spcat": return handleSpcat(Array(parts.dropFirst()))
        case "spmute" where parts.count == 1: return handleSpmute()
        case "spdebug" where parts.count == 1: return handleSpdebug()
        case "sphelp" where parts.count == 1: return handleSphelp()
        case "spfire" where parts.count == 2: return handleSpfire(parts[1].lowercased())
        default: return nil
        }
    }

    /// Plumbing, not a user command: fire one soundpack event through the
    /// user's config (volume/pan/custom wav, mute respected). This is how
    /// another plugin asks for an event cue — the reference's
    /// `CallPlugin(<soundpack>, "TriggerEvent", event)`; the S&D host routes
    /// its same-room target cue here. Always consumed (never reaches the
    /// MUD); unknown events are silently ignored like the reference.
    private mutating func handleSpfire(_ event: String) -> [ScriptEffect] {
        guard !config.muted, SoundpackConfig.isKnown(event) else { return [] }
        return cueEffects(for: event)
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
        case 4 where args[1].lowercased() == "wav":
            editVariants(args[0].lowercased(), action: args[2].lowercased(), file: args[3])
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
        for event in SoundpackConfig.eventNames {
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
                    text: Self.pad(Self.description(of: event), 42),
                    foreground: "#4682B4"
                )
            ]
            if let custom = config.events[event]?.files, let first = custom.first {
                let label = custom.count > 1 ? "\(first) +\(custom.count - 1)" : first
                segments.append(NoteSegment(text: label, foreground: "#3CB371"))
            }
            effects.append(.colourNote(segments))
        }
        return effects
    }

    private func showEvent(_ event: String) -> [ScriptEffect] {
        guard SoundpackConfig.isKnown(event) else {
            return [Self.errorNote("Invalid event: \(event)")]
        }
        var effects = [Self.note(
            "Event: \(event)\nVolume: \(config.volume(for: event)), "
                + "Panning: \(config.pan(for: event)) Desc: \(Self.description(of: event))"
        )]
        if let custom = config.events[event]?.files {
            effects.append(Self.note("Custom wav files set to: \(custom.joined(separator: ", "))"))
        }
        return effects
    }

    /// The reference's description, or a marker for a vocabulary event the
    /// reference has no sound for (the tag-sourced events).
    private static func description(of event: String) -> String {
        SoundEventClassifier.defaults[event]?.description ?? "(no default sound)"
    }

    private mutating func setEvent(_ event: String, setting: String, value: String) -> [ScriptEffect] {
        guard SoundpackConfig.isKnown(event) else {
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
                config.updateOverride(for: event) { $0.files = nil }
                saveConfig()
                return [Self.note("\(event) wav setting has been reset to default."), confirmationCue()]
            }
            config.updateOverride(for: event) { $0.files = [value] }
            saveConfig()
            return fileConfirmation("\(event) wav setting has been set to: \(value)", file: value)
        default:
            return [Self.errorNote("Unknown setting \"\(setting)\" — use volume, panning or wav.")]
        }
    }

    /// `spset <event> wav add|remove <file>`: edit the event's variant list.
    /// Adding starts from the event's current files, so the first `add` on a
    /// default event keeps the default as one of the variants.
    private mutating func editVariants(_ event: String, action: String, file: String) -> [ScriptEffect] {
        guard SoundpackConfig.isKnown(event) else {
            return [Self.errorNote("Invalid event: \(event)")]
        }
        var files = config.files(for: event)
        switch action {
        case "add":
            guard !files.contains(file) else {
                return [Self.errorNote("\(event) already plays \(file).")]
            }
            files.append(file)
            config.updateOverride(for: event) { $0.files = files }
            lastPicks[event] = nil
            saveConfig()
            return fileConfirmation("\(event) now plays one of: \(files.joined(separator: ", "))", file: file)
        case "remove":
            guard let index = files.firstIndex(of: file) else {
                return [Self.errorNote("\(event) doesn't play \(file).")]
            }
            // One way to silence an event (volume 0), not two: an empty list
            // would also be indistinguishable from "no override" on disk.
            guard files.count > 1 else {
                return [Self.errorNote(
                    "\(file) is \(event)'s only file — use \"spset \(event) wav default\" "
                        + "to restore the default, or \"sptog \(event)\" to silence it."
                )]
            }
            files.remove(at: index)
            config.updateOverride(for: event) { $0.files = files }
            lastPicks[event] = nil
            saveConfig()
            return [Self.note("\(event) now plays: \(files.joined(separator: ", "))"), confirmationCue()]
        default:
            return [Self.errorNote("Usage: spset <event> wav add|remove <file>")]
        }
    }

    /// A file-setting confirmation, with the missing-file courtesy note.
    private func fileConfirmation(_ message: String, file: String) -> [ScriptEffect] {
        var effects = [Self.note(message)]
        if Self.isMissingFromSoundsFolder(file) {
            effects.append(Self.note(
                "(\(file) isn't in your Sounds folder yet — a fallback cue plays until it is.)"
            ))
        }
        effects.append(confirmationCue())
        return effects
    }

    // MARK: - spcat

    /// `spcat` lists the category volumes; `spcat <category> <0-100>` sets
    /// one. A category caps every event in it, under the master (D-127).
    private mutating func handleSpcat(_ args: [String]) -> [ScriptEffect]? {
        switch args.count {
        case 0:
            var effects = [Self.note("Category volumes (each caps its events, under the global volume)")]
            for category in SemanticEvent.Category.allCases {
                effects.append(.colourNote([
                    NoteSegment(text: "  " + Self.pad(category.rawValue, 16), foreground: "#20B2AA"),
                    NoteSegment(text: "\(config.volume(for: category))%", foreground: "#4682B4")
                ]))
            }
            return effects
        case 2:
            guard let category = SemanticEvent.Category(rawValue: args[0].lowercased()) else {
                let names = SemanticEvent.Category.allCases.map(\.rawValue).joined(separator: ", ")
                return [Self.errorNote("Unknown category \"\(args[0])\" — use one of: \(names).")]
            }
            guard let volume = Int(args[1]), (0...100).contains(volume) else {
                return [Self.errorNote("Invalid value \"\(args[1])\" for volume — use 0-100.")]
            }
            config.setVolume(volume, for: category)
            saveConfig()
            return [Self.note("\(category.rawValue) volume has been set to: \(volume)"), confirmationCue()]
        default:
            return [Self.errorNote("Usage: spcat [category] [0-100]")]
        }
    }

    // MARK: - sptog / spvol / spmute / spdebug / sphelp

    private mutating func handleSptog(_ args: [String]) -> [ScriptEffect]? {
        guard args.count == 1 else {
            return [Self.errorNote("Usage: sptog <event>|all")]
        }
        let target = args[0].lowercased()
        if target == "all" {
            // Reference behaviour: every event flips independently — every
            // event that has a sound, so silent vocabulary events stay put.
            for event in SoundpackConfig.eventNames where !config.files(for: event).isEmpty {
                let current = config.volume(for: event)
                config.updateOverride(for: event) { $0.volume = current == 0 ? nil : 0 }
            }
            saveConfig()
            return [Self.note("All events have been toggled."), confirmationCue()]
        }
        guard SoundpackConfig.isKnown(target) else {
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
        let note = ScriptEffect.colourNote([
            NoteSegment(text: "[", foreground: "#4682B4"),
            NoteSegment(text: "Soundpack", foreground: "#3CB371"),
            NoteSegment(text: "] Soundpack has been: ", foreground: "#4682B4"),
            NoteSegment(text: state, foreground: color)
        ])
        // Effect order matters: the session's master gate applies in
        // sequence, so unmuting opens the gate BEFORE the confirmation cue,
        // and muting closes it AFTER — the reference plays audible feedback
        // on disable too (PlaySettingChanged bypasses its own mute).
        return config.muted
            ? [note, confirmationCue(), .setSoundCuesMuted(true)]
            : [.setSoundCuesMuted(false), note, confirmationCue()]
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
