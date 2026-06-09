import MudCore
import Observation
import SwiftUI

/// `@Observable` view-model bridging the `ProfileStore` actor to
/// SwiftUI (PLAN.md §8.4).
///
/// `ProfileStore` is the source of truth and lives on its own actor;
/// SwiftUI needs synchronous, main-actor state to bind to. This model
/// mirrors the store's `profiles` + `activeProfileID` into observable
/// properties and forwards mutations back to the store, refreshing
/// afterwards.
///
/// Editing is live: ``binding(for:)`` returns a `Binding<WorldProfile>`
/// that updates the in-memory copy immediately (so the UI is snappy)
/// and writes through to the store. The profile document is tiny, so
/// persisting on each edit is fine; debouncing can come later if it
/// ever matters.
@MainActor
@Observable
public final class WorldsModel {
    public private(set) var profiles: [WorldProfile] = []
    public private(set) var activeProfileID: UUID?

    /// The row currently selected in the Connection Manager list.
    public var selectedID: UUID?

    private let store: ProfileStore
    private let credentials: CredentialStore
    /// Kept pointed at the active profile's transport so the session's
    /// `makeConnection` builds the right ``MudConnection`` (#ws).
    private let transportSelector: TransportSelector?

    public init(
        store: ProfileStore,
        credentials: CredentialStore = KeychainStore(),
        transportSelector: TransportSelector? = nil
    ) {
        self.store = store
        self.credentials = credentials
        self.transportSelector = transportSelector
    }

    /// The active profile resolved from ``activeProfileID``.
    public var activeProfile: WorldProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    /// Load (or seed) the store and mirror its state. Selects the active
    /// profile (or the first one) if nothing is selected yet.
    public func load() async {
        try? await store.load()
        await refresh()
        if selectedID == nil {
            selectedID = activeProfileID ?? profiles.first?.id
        }
    }

    /// Add a blank profile and select it for editing.
    public func addProfile() async {
        let new = WorldProfile(name: "New World", host: "", port: 4000)
        try? await store.add(new)
        await refresh()
        selectedID = new.id
    }

    /// Remove the selected profile; re-select the active or first
    /// remaining profile.
    public func removeSelected() async {
        guard let selectedID else { return }
        credentials.removePassword(forAccount: Autologin.passwordAccount(for: selectedID))
        try? await store.remove(id: selectedID)
        await refresh()
        self.selectedID = activeProfileID ?? profiles.first?.id
    }

    /// Mark a profile active.
    public func setActive(_ id: UUID) async {
        try? await store.setActive(id: id)
        await refresh()
    }

    /// A two-way binding to the profile with `id`, for the editor form.
    /// Returns `nil` if no such profile exists. The setter updates the
    /// in-memory array synchronously and persists to the store
    /// asynchronously.
    public func binding(for id: UUID) -> Binding<WorldProfile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.profiles.first { $0.id == id }
                    ?? WorldProfile(name: "", host: "", port: 0)
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[index] = newValue
                }
                Task { try? await self.store.update(newValue) }
            }
        )
    }

    // MARK: - Credentials

    /// Read the stored autologin password for `id` (empty string if
    /// none). Backed by the ``CredentialStore`` — the Keychain in the
    /// app, an in-memory store in tests.
    public func password(for id: UUID) -> String {
        credentials.password(forAccount: Autologin.passwordAccount(for: id)) ?? ""
    }

    /// Store (or clear, when empty) the autologin password for `id`.
    public func setPassword(_ password: String, for id: UUID) {
        credentials.setPassword(password, forAccount: Autologin.passwordAccount(for: id))
    }

    /// Resolve the connect-time autologin instruction for `profile`,
    /// folding in its password from the credential store. `nil` when
    /// autologin is not configured.
    public func autologinPlan(for profile: WorldProfile) -> AutologinPlan? {
        profile.autologinPlan(using: credentials)
    }

    // MARK: - Private

    private func refresh() async {
        profiles = await store.profiles
        activeProfileID = await store.activeProfileID
        // Keep the transport selector aligned with the active world (#ws).
        transportSelector?.set(activeProfile?.transport ?? .direct)
    }
}
