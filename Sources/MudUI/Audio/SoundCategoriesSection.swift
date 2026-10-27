import MudCore
import SwiftUI

/// Settings ▸ Audio's per-category controls (S1 step 6, #83): one volume cap
/// per category — the `spcat` value, a cap per D-127 (2) — and, under each,
/// its events with a ▶ that previews exactly what would play in-game.
/// Per-event volume, pan and files stay on `spset` (D-122: no per-event
/// configuration surface in V1). Platform-neutral: the host saves on slider
/// release and supplies the player (`docs/plans/S1_ITEM6_PROPOSAL.md`).
public struct SoundCategoriesSection: View {
    @Binding private var config: SoundpackConfig
    private let onCommit: () -> Void
    private let preview: (SoundCue) -> Void

    /// - Parameters:
    ///   - config: the soundpack config the window edits.
    ///   - onCommit: save and reload, called when a slider is released.
    ///   - preview: play a cue, bypassing the soundpack's mute.
    public init(
        config: Binding<SoundpackConfig>,
        onCommit: @escaping () -> Void,
        preview: @escaping (SoundCue) -> Void
    ) {
        _config = config
        self.onCommit = onCommit
        self.preview = preview
    }

    public var body: some View {
        Section("Categories") {
            Text("Each category's volume caps its sounds, under the master volume. "
                + "Expand a category to hear its sounds; tune single events with `spset`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(SemanticEvent.Category.allCases, id: \.self) { category in
                categoryRow(category)
            }
        }
    }

    private func categoryRow(_ category: SemanticEvent.Category) -> some View {
        DisclosureGroup {
            if let note = SoundCategoryText.note(for: category) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(SoundEventPreview.rows(in: category, config: config), id: \.event) { row in
                    eventRow(row)
                }
            }
        } label: {
            LabeledContent(SoundCategoryText.title(for: category)) {
                HStack {
                    Slider(value: volume(category), in: 0...100, step: 5) { editing in
                        if !editing { onCommit() }
                    }
                    .frame(maxWidth: 180)
                    Text("\(config.volume(for: category))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func eventRow(_ row: SoundEventPreview) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(row.event).font(.body.monospaced())
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let cue = row.cue { preview(cue) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(row.cue == nil)
            .help(row.cue == nil ? row.silentReason : "Play \(row.event)")
        }
    }

    private func volume(_ category: SemanticEvent.Category) -> Binding<Double> {
        Binding(
            get: { Double(config.volume(for: category)) },
            set: { config.setVolume(Int($0), for: category) }
        )
    }
}

/// One event under a category, as Settings ▸ Audio lists it. Pure, so it is
/// tested without a view.
public struct SoundEventPreview: Sendable, Equatable {
    public let event: String
    /// The reference's description and the file(s) it plays.
    public let detail: String
    /// What ▶ plays — the cue map's cue at the effective volume — or nil
    /// when there is no file or the volume is 0.
    public let cue: SoundCue?
    /// Why ▶ is disabled, when it is.
    public let silentReason: String

    /// The rows for `category`'s events under `config`.
    public static func rows(in category: SemanticEvent.Category, config: SoundpackConfig) -> [Self] {
        SemanticEventVocabulary.events(in: category).map { event in
            let files = config.files(for: event)
            let description = SoundEventClassifier.defaults[event]?.description
            let fileText = files.isEmpty ? "no sound set" : files.joined(separator: ", ")
            return Self(
                event: event,
                detail: [description, fileText].compactMap(\.self).joined(separator: " — "),
                cue: config.cue(for: event)?.cue,
                silentReason: files.isEmpty
                    ? "No sound set — `spset \(event) wav <file>`"
                    : "Volume is 0 — raise the event, its category or the master"
            )
        }
    }
}

/// Settings ▸ Audio's words for each category.
public enum SoundCategoryText {
    public static func title(for category: SemanticEvent.Category) -> String {
        switch category {
        case .communication: "Channels and tells"
        case .world: "World and quests"
        case .combat: "Combat"
        case .progression: "Progression"
        case .affect: "Spells and skills"
        case .inventory: "Items"
        case .group: "Group"
        case .system: "Server messages"
        case .custom: "Your triggers"
        case .notification: "Notifications"
        }
    }

    /// For a category whose sounds are chosen elsewhere, where to choose
    /// them — shown in place of an event list.
    public static func note(for category: SemanticEvent.Category) -> String? {
        switch category {
        case .custom: "Choose sounds per trigger in Scripts."
        case .notification:
            "Plays even when event sounds are off. Choose sounds per rule in Notifications."
        default: nil
        }
    }
}
