import Foundation
@testable import MudCore
import Testing

@Suite("ButtonBar — model, toggle action, persistence (#15)")
struct ButtonBarTests {
    @Test("momentary fires its action; a toggle picks on/off by current state")
    func toggleAction() {
        let momentary = CommandButton(label: "Recall", action: .command("recall"))
        #expect(momentary.action(currentlyOn: false) == .command("recall"))
        #expect(momentary.action(currentlyOn: true) == .command("recall"))
        #expect(!momentary.isToggle)

        let wimpy = CommandButton(
            label: "Wimpy",
            action: .command("wimpy 200"),
            kind: .toggle(off: .command("wimpy 0"))
        )
        #expect(wimpy.isToggle)
        #expect(wimpy.action(currentlyOn: false) == .command("wimpy 200")) // switching on
        #expect(wimpy.action(currentlyOn: true) == .command("wimpy 0")) // switching off
    }

    @Test("find locates a button + its group across groups")
    func find() {
        let target = CommandButton(label: "Cast", action: .command("cast 'armor'"))
        let combat = ButtonGroup(name: "Combat", buttons: [target])
        let travel = ButtonGroup(name: "Travel", buttons: [CommandButton(label: "N", action: .command("n"))])
        let bar = ButtonBar(groups: [travel, combat])
        #expect(bar.find(target.id)?.group == combat.id)
        #expect(bar.find(UUID()) == nil)
        #expect(!bar.isEmpty)
        #expect(ButtonBar(groups: [ButtonGroup(name: "Empty")]).isEmpty)
    }

    @Test("ButtonBar round-trips through Codable, including toggle + styling")
    func codableRoundTrip() throws {
        let bar = ButtonBar(groups: [
            ButtonGroup(name: "Combat", buttons: [
                CommandButton(
                    label: "Heal",
                    action: .command("quaff heal"),
                    tint: "#33CC66",
                    icon: "cross.vial"
                ),
                CommandButton(
                    label: "Wimpy",
                    action: .script("wimpyOn()"),
                    kind: .toggle(off: .script("wimpyOff()"))
                )
            ])
        ])
        let data = try JSONEncoder().encode(bar)
        let decoded = try JSONDecoder().decode(ButtonBar.self, from: data)
        #expect(decoded == bar)
    }

    @Test("apply add/toggle/remove mutate the bar; setState leaves content unchanged")
    func applyCommands() {
        var bar = ButtonBar()
        bar.apply(.add(group: "Combat", label: "Heal", command: "quaff heal"))
        #expect(bar.button(label: "Heal")?.action == .command("quaff heal"))
        #expect(bar.groups.first?.name == "Combat") // group auto-created
        // Re-adding the same label updates in place (no duplicate).
        bar.apply(.add(group: "Combat", label: "Heal", command: "drink heal"))
        #expect(bar.groups.flatMap(\.buttons).count(where: { $0.label == "Heal" }) == 1)
        #expect(bar.button(label: "Heal")?.action == .command("drink heal"))
        // Toggle.
        bar.apply(.toggle(group: "Combat", label: "Wimpy", on: "wimpy 200", off: "wimpy 0"))
        #expect(bar.button(label: "Wimpy")?.isToggle == true)
        // setState doesn't alter bar content (it's transient UI state).
        let snapshot = bar
        bar.apply(.setState(label: "Wimpy", on: true))
        #expect(bar == snapshot)
        // Remove.
        bar.apply(.remove(label: "Heal"))
        #expect(bar.button(label: "Heal") == nil)
    }

    @Test("button(forHotkey:) finds the button bound to a chord across groups (#40)")
    func buttonForHotkey() {
        let chord = KeyChord(keyCode: 122, isFunctionKey: true) // F1
        let bar = ButtonBar(groups: [
            ButtonGroup(name: "Combat", buttons: [
                CommandButton(label: "Kick", action: .command("kick")),
                CommandButton(label: "Bash", action: .command("bash"), hotkeyEcho: chord)
            ]),
            ButtonGroup(name: "Travel", buttons: [
                CommandButton(label: "Recall", action: .command("recall"))
            ])
        ])
        #expect(bar.button(forHotkey: chord)?.label == "Bash")
        // An unbound chord matches nothing.
        #expect(bar.button(forHotkey: KeyChord(keyCode: 120, isFunctionKey: true)) == nil)
    }

    @Test("ScriptDocument tolerates a file written before buttonBar existed")
    func documentBackwardCompatible() throws {
        // An older document JSON with no buttonBar key still decodes (empty bar).
        let legacy = #"{"triggers":[],"aliases":[],"timers":[],"macros":[]}"#
        let document = try JSONDecoder().decode(ScriptDocument.self, from: Data(legacy.utf8))
        #expect(document.buttonBar.isEmpty)
        // And a round-trip preserves a populated bar.
        var populated = ScriptDocument()
        populated.buttonBar = ButtonBar(groups: [ButtonGroup(name: "G", buttons: [
            CommandButton(label: "L", action: .command("c"))
        ])])
        let data = try JSONEncoder().encode(populated)
        #expect(try JSONDecoder().decode(ScriptDocument.self, from: data).buttonBar == populated.buttonBar)
    }
}
