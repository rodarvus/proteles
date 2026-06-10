import MudCore
import SwiftUI

/// The Lua Console window: a live stream of script errors (attributed to the
/// plugin that raised them) interleaved with a REPL — type Lua, pick which
/// loaded plugin's environment it runs in, see results inline. The window
/// equivalent of `/lua`, plus the diagnostics MUSHclient buried in its error
/// window.
public struct LuaConsoleView: View {
    @Bindable private var model: LuaConsoleModel

    public init(model: LuaConsoleModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .frame(minWidth: 480, minHeight: 280)
        .onAppear { model.start() }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if model.lines.isEmpty {
            ContentUnavailableView(
                "Lua Console",
                systemImage: "terminal",
                description: Text(
                    "Script errors appear here as they happen, with the plugin that raised them. "
                        + "Type Lua below to inspect or poke at the live session."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lines) { line in
                            row(line)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.lines.count) {
                    if let last = model.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ line: ScriptDiagnostic) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            if let source = line.source {
                Text(source)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Text(line.severity == .input ? "› \(line.message)" : line.message)
                .font(.callout.monospaced())
                .foregroundStyle(colour(for: line.severity))
                .textSelection(.enabled)
        }
    }

    private func colour(for severity: ScriptDiagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .output: .primary
        case .input: .secondary
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Picker("Environment", selection: $model.selectedEnvironment) {
                Text("User").tag(String?.none)
                ForEach(model.environments) { environment in
                    Text(environment.name).tag(String?.some(environment.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Which Lua environment the code runs in")
            .onHover { hovering in
                if hovering { model.refreshEnvironments() }
            }

            TextField("Lua…", text: $model.input)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .onSubmit { model.submit() }
                .onKeyPress(.upArrow) {
                    model.historyBack()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.historyForward()
                    return .handled
                }

            Button("Clear") { model.clear() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }
}
