import MudCore
import MudUI
import SwiftUI

extension ContentView {
    /// Toolbar menu to show/hide each panel + reset the layout.
    var panelsMenu: some View {
        Menu {
            ForEach(PanelKind.toggleable) { kind in
                Toggle(isOn: Binding(
                    get: { layout.isVisible(kind) },
                    set: { _ in layout.toggle(kind) }
                )) {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
            Divider()
            if !layout.presets.isEmpty {
                Menu("Apply Layout") {
                    ForEach(layout.presets) { preset in
                        Button(preset.name) { layout.applyPreset(preset) }
                    }
                }
                Menu("Delete Layout") {
                    ForEach(layout.presets) { preset in
                        Button(preset.name) { layout.deletePreset(named: preset.name) }
                    }
                }
            }
            Button("Save Layout…") { newPresetName = ""; showingSavePreset = true }
            Button("Reset Layout") { layout.resetToDefault() }
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .help("Show or hide panels")
    }
}
