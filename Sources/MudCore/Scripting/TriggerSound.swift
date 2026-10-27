import Foundation

/// A trigger's sound (S1 step 4, #83, D-127 (3)). Firing it **emits a
/// ``SemanticEvent``**; the cue map turns that into a cue, so category
/// volumes, variants, playback discipline and the soundpack's mute apply as
/// to any other event. Nothing in the trigger path plays a file
/// (`docs/plans/S1_ITEM4_PROPOSAL.md`).
public enum TriggerSound: Sendable, Equatable, Codable {
    /// A vocabulary event (`tell`, `level_up` …): plays that event's cue.
    case event(name: String)
    /// A file in the Sounds folder, by name: plays as the fixed
    /// ``triggerSoundEvent`` in the ``SemanticEvent/Category/custom`` category.
    case file(name: String)

    /// The one event every `.file` sound plays as.
    public static let triggerSoundEvent = "trigger_sound"
    /// The `.file` event's payload key for the file name.
    public static let filePayloadKey = "file"

    /// A MUSHclient trigger's `sound` attribute as a file sound, keeping only
    /// the file name: MUSHclient stores a path (often absolute and Windows,
    /// `C:\Windows\Media\…\x.wav`), and Proteles looks the name up in
    /// the Sounds folder. MUSHclient's `(No sound)` and an empty value are none.
    public static func imported(_ attribute: String?) -> TriggerSound? {
        guard let attribute else { return nil }
        let path = attribute.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path != "(No sound)" else { return nil }
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        return name.isEmpty ? nil : .file(name: name)
    }

    /// The event this sound emits for a firing of `trigger`. The source is
    /// `.pattern` — a user's trigger is a prose match, the weakest tier —
    /// named like the notification rules' `user.<label>`.
    public func event(for trigger: String) -> SemanticEvent? {
        let source = SemanticEvent.Source.pattern(rule: "trigger.\(trigger)")
        switch self {
        case .event(let name):
            guard let category = SemanticEventVocabulary.category(for: name) else { return nil }
            return SemanticEvent(category: category, name: name, source: source)
        case .file(let name):
            guard !name.isEmpty else { return nil }
            return SemanticEvent(
                category: .custom,
                name: Self.triggerSoundEvent,
                source: source,
                payload: [Self.filePayloadKey: name]
            )
        }
    }
}
