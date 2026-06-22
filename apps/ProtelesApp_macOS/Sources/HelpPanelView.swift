import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

/// The in-game **Help** panel: renders the captured help article (styled, with
/// clickable `help <topic>` cross-references via the shared output view) plus a
/// search field and back/forward history. Help capture is enabled while this
/// panel is visible (see ``ContentView``); clicking a topic or submitting the
/// search routes `help …` to the session, whose reply lands as the next article.
struct HelpPanelView: View {
    let model: HelpPanelModel
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("outputFontSize") private var outputFontSize = 13.0
    @AppStorage("outputFontName") private var outputFontName = "JetBrains Mono NL"
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                MudOutputView(
                    store: model.store,
                    palette: palette,
                    fontSize: CGFloat(outputFontSize),
                    fontName: outputFontName,
                    showsLiveTail: false,
                    onCommand: { command in model.onCommand?(command) }
                )
                .id(model.renderToken)

                if !model.hasContent {
                    ContentUnavailableView(
                        "In-Game Help",
                        systemImage: "questionmark.circle",
                        description: Text("Type `help <topic>` or search above. "
                            + "Related topics become clickable.")
                    )
                }
            }
        }
    }

    private var palette: ColorPalette {
        _ = themeRevision
        return Theme.with(id: themeID).palette
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.back() }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            .help("Back")

            Button {
                Task { await model.forward() }
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            .help("Forward")

            Text(model.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            TextField("Search help…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit {
                    model.search(query)
                    query = ""
                }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
