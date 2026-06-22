import MudCore
import SwiftUI

struct ThemeBrowserSheet: View {
    @Binding var selectedThemeID: String
    @Binding var themeRevision: Int
    let fontSize: Double
    let fontName: String
    let duplicateAndEdit: (Theme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var browsingID: String

    init(
        selectedThemeID: Binding<String>,
        themeRevision: Binding<Int>,
        fontSize: Double,
        fontName: String,
        duplicateAndEdit: @escaping (Theme) -> Void
    ) {
        _selectedThemeID = selectedThemeID
        _themeRevision = themeRevision
        self.fontSize = fontSize
        self.fontName = fontName
        self.duplicateAndEdit = duplicateAndEdit
        _browsingID = State(initialValue: selectedThemeID.wrappedValue)
    }

    private var browsingTheme: Theme {
        Theme.with(id: browsingID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                themeList
                    .frame(width: 210)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Duplicate & Edit…") {
                    let copy = ThemeStore.shared.duplicateTheme(id: browsingID)
                    selectedThemeID = copy.id
                    themeRevision += 1
                    duplicateAndEdit(copy)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    selectedThemeID = browsingID
                    themeRevision += 1
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var themeList: some View {
        List {
            Section("Built-in") {
                ForEach(Theme.builtIns) { themeRow($0) }
            }
            if !ThemeStore.shared.themes.isEmpty {
                Section("Custom") {
                    ForEach(ThemeStore.shared.themes) { themeRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(browsingTheme.name).font(.title3.weight(.semibold))
                    Text(browsingTheme.appearance == .light ? "Light" : "Dark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if browsingTheme.id == selectedThemeID {
                        Text("Current").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                ThemePreview(theme: browsingTheme, fontSize: fontSize, fontName: fontName)
                ThemePaletteGrid(theme: browsingTheme)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func themeRow(_ theme: Theme) -> some View {
        Button {
            browsingID = theme.id
        } label: {
            HStack {
                Text(theme.name)
                Spacer()
                if theme.id == selectedThemeID {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.id == browsingID ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
