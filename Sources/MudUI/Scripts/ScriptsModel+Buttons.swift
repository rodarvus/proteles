import MudCore
import SwiftUI

/// Command-button bar (#15) mutations + firing, split out of ``ScriptsModel`` to
/// keep that file within budget. Edits persist to the per-world ``ScriptStore``
/// (so the bar saves like triggers/aliases/timers) and re-mirror; toggle state
/// is transient.
public extension ScriptsModel {
    /// Apply a mutation to the button bar, persist it, and re-mirror. The
    /// transform runs synchronously before the store write, so it needn't be
    /// `Sendable`.
    func updateButtonBar(_ transform: (inout ButtonBar) -> Void) async {
        guard let store else { return }
        var bar = await store.buttonBar
        transform(&bar)
        try? await store.setButtonBar(bar)
        await refresh()
    }

    func addButtonGroup() async {
        let group = ButtonGroup(name: "Group \(buttonBar.groups.count + 1)")
        await updateButtonBar { $0.groups.append(group) }
        selectedButtonGroupID = group.id
    }

    func deleteButtonGroup(_ id: UUID) async {
        await updateButtonBar { bar in bar.groups.removeAll { $0.id == id } }
        if selectedButtonGroupID == id { selectedButtonGroupID = buttonBar.groups.first?.id }
    }

    func moveButtonGroups(from offsets: IndexSet, to destination: Int) async {
        await updateButtonBar { $0.groups.move(fromOffsets: offsets, toOffset: destination) }
    }

    func addButton(toGroup groupID: UUID) async {
        let button = CommandButton(label: "New", action: .command(""))
        await updateButtonBar { bar in
            guard let index = bar.groups.firstIndex(where: { $0.id == groupID }) else { return }
            bar.groups[index].buttons.append(button)
        }
        selectedButtonID = button.id
    }

    func deleteButton(_ id: UUID) async {
        await updateButtonBar { bar in
            for index in bar.groups.indices {
                bar.groups[index].buttons.removeAll { $0.id == id }
            }
        }
        if selectedButtonID == id { selectedButtonID = nil }
    }

    func moveButtons(inGroup groupID: UUID, from offsets: IndexSet, to destination: Int) async {
        await updateButtonBar { bar in
            guard let index = bar.groups.firstIndex(where: { $0.id == groupID }) else { return }
            bar.groups[index].buttons.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    /// A binding to one button for the editor (writes back + persists).
    func binding(forButton id: UUID) -> Binding<CommandButton>? {
        guard buttonBar.find(id) != nil else { return nil }
        return Binding(
            get: { [weak self] in
                self?.buttonBar.find(id)?.button ?? CommandButton(label: "", action: .command(""))
            },
            set: { [weak self] newValue in
                guard let self else { return }
                Task { await self.updateButtonBar { bar in
                    for group in bar.groups.indices {
                        if let button = bar.groups[group].buttons.firstIndex(where: { $0.id == id }) {
                            bar.groups[group].buttons[button] = newValue
                            return
                        }
                    }
                } }
            }
        )
    }

    /// A binding to a group's name for the editor.
    func bindingForGroupName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.buttonBar.groups.first { $0.id == id }?.name ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                Task { await self.updateButtonBar { bar in
                    if let index = bar.groups.firstIndex(where: { $0.id == id }) {
                        bar.groups[index].name = newValue
                    }
                } }
            }
        )
    }

    /// Apply a script/plugin-issued button command (#15 v3): add/toggle/remove
    /// persist to the bar; setState flips transient toggle state by label.
    func applyButtonCommand(_ command: ButtonCommand) async {
        if case .setState(let label, let on) = command {
            if let button = buttonBar.button(label: label) { buttonToggleStates[button.id] = on }
            return
        }
        await updateButtonBar { $0.apply(command) }
    }

    /// Fire a button: resolve its action for the current toggle state, send it
    /// through the session, then flip the toggle's transient state.
    func fireButton(_ id: UUID) async {
        guard let (_, button) = buttonBar.find(id) else { return }
        let isOn = buttonToggleStates[id] ?? false
        await session.fire(button.action(currentlyOn: isOn))
        if button.isToggle { buttonToggleStates[id] = !isOn }
    }
}
