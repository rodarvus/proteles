import AppKit
import MudCore
import MudUI
import SwiftUI

struct ThemeEditorSheet: View {
    let initialTheme: Theme
    @Binding var selectedThemeID: String
    @Binding var themeRevision: Int
    let fontSize: Double
    let fontName: String

    @Environment(\.dismiss) private var dismiss
    @State private var theme: Theme

    init(
        initialTheme: Theme,
        selectedThemeID: Binding<String>,
        themeRevision: Binding<Int>,
        fontSize: Double,
        fontName: String
    ) {
        self.initialTheme = initialTheme
        _selectedThemeID = selectedThemeID
        _themeRevision = themeRevision
        self.fontSize = fontSize
        self.fontName = fontName
        _theme = State(initialValue: initialTheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    ThemePreview(theme: theme, fontSize: fontSize, fontName: fontName)
                    defaultsSection
                    ansiSection("Normal ANSI", keyPath: \.named)
                    ansiSection("Bright ANSI", keyPath: \.brightNamed)
                    behaviorSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Saved to Settings/themes.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    ThemeStore.shared.upsert(theme)
                    selectedThemeID = theme.id
                    themeRevision += 1
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Theme").font(.headline)
            TextField("Name", text: $theme.name)
            Picker("Appearance", selection: $theme.appearance) {
                Text("Dark").tag(Theme.Appearance.dark)
                Text("Light").tag(Theme.Appearance.light)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Defaults").font(.headline)
            ThemeColorPicker(title: "Text", rgb: rgbBinding(
                get: { $0.palette.defaultForeground },
                set: { $0.palette.defaultForeground = $1 }
            ))
            ThemeColorPicker(title: "Background", rgb: rgbBinding(
                get: { $0.palette.defaultBackground },
                set: { $0.palette.defaultBackground = $1 }
            ))
        }
    }

    private func ansiSection(
        _ title: String,
        keyPath: WritableKeyPath<ColorPalette, [NamedColor: RGB]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(
                columns: [GridItem(.fixed(120)), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(NamedColor.allCases, id: \.self) { name in
                    Text(name.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ThemeColorPicker(title: name.label, labelsHidden: true, rgb: rgbBinding(
                        get: { $0.palette[keyPath: keyPath][name] ?? $0.palette.defaultForeground },
                        set: { $0.palette[keyPath: keyPath][name] = $1 }
                    ))
                }
            }
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendering").font(.headline)
            Toggle("Remap very dark xterm colours", isOn: $theme.palette.remapsDarkXterm)
            Toggle("Clamp low-contrast foregrounds", isOn: clampEnabled)
            if theme.palette.minForegroundContrast != nil {
                HStack {
                    Slider(value: clampValue, in: 1...7, step: 0.25)
                    Text(String(format: "%.2f", theme.palette.minForegroundContrast ?? 3))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private var clampEnabled: Binding<Bool> {
        Binding(
            get: { theme.palette.minForegroundContrast != nil },
            set: { theme.palette.minForegroundContrast = $0 ? 3 : nil }
        )
    }

    private var clampValue: Binding<Double> {
        Binding(
            get: { theme.palette.minForegroundContrast ?? 3 },
            set: { theme.palette.minForegroundContrast = $0 }
        )
    }

    private func rgbBinding(
        get: @escaping (Theme) -> RGB,
        set: @escaping (inout Theme, RGB) -> Void
    ) -> Binding<RGB> {
        Binding(
            get: { get(theme) },
            set: { value in
                var edited = theme
                set(&edited, value)
                theme = edited
            }
        )
    }
}

private struct ThemeColorPicker: View {
    let title: String
    var labelsHidden = false
    @Binding var rgb: RGB
    @State private var showingNamedColours = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                Button {
                    showingNamedColours = true
                } label: {
                    Label("Named", systemImage: "swatchpalette")
                }
                .popover(isPresented: $showingNamedColours, arrowEdge: .bottom) {
                    NamedColourPopover(current: rgb) { choice in
                        rgb = choice.rgb
                        showingNamedColours = false
                    }
                }
                TextField("Hex", text: hexBinding)
                    .font(.callout.monospacedDigit())
                    .frame(width: 86)
            }
        } label: {
            if !labelsHidden {
                Text(title)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(rgb) },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                rgb = RGB(
                    UInt8(clamping: Int((ns.redComponent * 255).rounded())),
                    UInt8(clamping: Int((ns.greenComponent * 255).rounded())),
                    UInt8(clamping: Int((ns.blueComponent * 255).rounded()))
                )
            }
        )
    }

    private var hexBinding: Binding<String> {
        Binding(
            get: { rgb.hexString },
            set: { value in
                if let parsed = RGB(hex: value) { rgb = parsed }
            }
        )
    }
}

private struct NamedColourPopover: View {
    typealias Choice = MUSHColour.NamedColourChoice

    let current: RGB
    let select: (Choice) -> Void

    @State private var searchText = ""

    private var nearbyChoices: [Choice] {
        Array(MUSHColour.namedColourChoices
            .sorted { lhs, rhs in lhs.rgb.distance(to: current) < rhs.rgb.distance(to: current) }
            .prefix(12))
    }

    private var allChoices: [Choice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return MUSHColour.namedColourChoices }
        return MUSHColour.namedColourChoices.filter { choice in
            choice.name.contains(query) || choice.rgb.hexString.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section {
                            ForEach(nearbyChoices) { choice in
                                NamedColourRow(
                                    choice: choice,
                                    isSelected: choice.rgb == current,
                                    select: select
                                )
                            }
                        } header: {
                            sectionHeader("Nearby")
                        }
                    }
                    Section {
                        ForEach(allChoices) { choice in
                            NamedColourRow(choice: choice, isSelected: choice.rgb == current, select: select)
                        }
                    } header: {
                        sectionHeader("All Named Colours")
                    }
                }
            }
            .frame(width: 300, height: 360)
        }
        .padding(12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(.regularMaterial)
    }
}

private struct NamedColourRow: View {
    let choice: MUSHColour.NamedColourChoice
    let isSelected: Bool
    let select: (MUSHColour.NamedColourChoice) -> Void

    var body: some View {
        Button {
            select(choice)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(choice.rgb))
                    .frame(width: 24, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
                Text(choice.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(choice.rgb.hexString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("\(choice.name) \(choice.rgb.hexString)")
    }
}

private extension RGB {
    func distance(to other: RGB) -> Double {
        let redMean = (Double(red) + Double(other.red)) / 2
        let redDelta = Double(red) - Double(other.red)
        let greenDelta = Double(green) - Double(other.green)
        let blueDelta = Double(blue) - Double(other.blue)
        let redWeight = 2 + redMean / 256
        let blueWeight = 2 + (255 - redMean) / 256
        return sqrt(
            redWeight * redDelta * redDelta
                + 4 * greenDelta * greenDelta
                + blueWeight * blueDelta * blueDelta
        )
    }
}

private extension NamedColor {
    var label: String {
        switch self {
        case .black: "Black"
        case .red: "Red"
        case .green: "Green"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .magenta: "Magenta"
        case .cyan: "Cyan"
        case .white: "White"
        }
    }
}
