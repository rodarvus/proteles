import MudCore
import SwiftUI

/// The "Worlds" window: master-detail manager for ``WorldProfile``s
/// (PLAN.md §8.4).
///
/// Left: a selectable list of worlds with add/remove controls and an
/// active-world indicator. Right: the editor for the selected world.
/// `onConnect` is invoked when the user asks to connect — the app
/// wires it to "make active, (re)connect the session, close this
/// window".
public struct ConnectionManagerView: View {
    @Bindable private var model: WorldsModel
    private let onConnect: (WorldProfile) -> Void

    public init(
        model: WorldsModel,
        onConnect: @escaping (WorldProfile) -> Void
    ) {
        self.model = model
        self.onConnect = onConnect
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.profiles) { profile in
                    WorldRow(
                        profile: profile,
                        isActive: profile.id == model.activeProfileID
                    )
                    .tag(profile.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.addProfile() }
                    } label: {
                        Label("Add World", systemImage: "plus")
                    }
                    Button {
                        Task { await model.removeSelected() }
                    } label: {
                        Label("Remove World", systemImage: "minus")
                    }
                    .disabled(model.selectedID == nil)
                }
            }
        } detail: {
            detail
        }
        .navigationTitle("Worlds")
        .task { await model.load() }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedID, let binding = model.binding(for: id) {
            WorldEditorView(
                profile: binding,
                isActive: id == model.activeProfileID,
                onMakeActive: { Task { await model.setActive(id) } },
                onConnect: { onConnect(binding.wrappedValue) }
            )
        } else {
            ContentUnavailableView(
                "No World Selected",
                systemImage: "globe",
                description: Text("Select a world from the list, or add a new one.")
            )
        }
    }
}

/// One row in the worlds list: name, host:port subtitle, and a green
/// dot when this is the active world.
private struct WorldRow: View {
    let profile: WorldProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.clear)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? "New World" : profile.name)
                Text("\(profile.host.isEmpty ? "—" : profile.host):\(String(profile.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
