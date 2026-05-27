import Foundation
@testable import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("LayoutStore — detachable windows")
struct LayoutStoreDetachTests {
    /// A store on a throwaway UserDefaults key so tests don't touch real layout.
    private func makeStore() -> LayoutStore {
        LayoutStore(persistenceKey: "test.layout.\(UUID().uuidString)")
    }

    @Test("Detaching pulls a panel out of the dock but keeps it visible")
    func detachRemovesFromDock() {
        let store = makeStore()
        store.detach(.map)
        #expect(store.isDetached(.map))
        #expect(!store.layout.contains(.map), "detached panel must leave the dock tree")
        #expect(store.isVisible(.map), "a detached panel still counts as visible")
    }

    @Test("Re-docking returns the panel to the dock")
    func redockReturnsToDock() {
        let store = makeStore()
        store.detach(.channels)
        store.redock(.channels)
        #expect(!store.isDetached(.channels))
        #expect(store.layout.contains(.channels), "re-docked panel must be back in the tree")
    }

    @Test("Closing a detached window (hideDetached) hides the panel entirely")
    func hideDetachedHides() {
        let store = makeStore()
        store.detach(.hunt)
        store.hideDetached(.hunt)
        #expect(!store.isDetached(.hunt))
        #expect(!store.layout.contains(.hunt), "a closed detached window must not re-dock")
        #expect(!store.isVisible(.hunt))
    }

    @Test("Toggling a detached panel off closes its window")
    func toggleClosesDetached() {
        let store = makeStore()
        store.detach(.map)
        store.toggle(.map)
        #expect(!store.isDetached(.map), "toggle should hide the detached panel")
        #expect(!store.layout.contains(.map))
    }

    @Test("The permanent output panel cannot be detached")
    func outputNotDetachable() {
        let store = makeStore()
        store.detach(.output)
        #expect(!store.isDetached(.output))
        #expect(store.layout.contains(.output))
    }

    @Test("Reset re-docks everything and clears detached windows")
    func resetClearsDetached() {
        let store = makeStore()
        store.detach(.map)
        store.detach(.channels)
        store.resetToDefault()
        #expect(store.detached.isEmpty)
        #expect(store.layout == .standard)
    }
}
