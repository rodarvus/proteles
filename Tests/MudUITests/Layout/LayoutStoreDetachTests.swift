import Foundation
@testable import MudCore
@testable import MudUI
import Testing

@MainActor
@Suite("LayoutStore — detachable windows")
struct LayoutStoreDetachTests {
    /// A store on throwaway UserDefaults keys so tests don't touch real
    /// layout/presets.
    private func makeStore() -> LayoutStore {
        let id = UUID().uuidString
        return LayoutStore(persistenceKey: "test.layout.\(id)", presetsKey: "test.presets.\(id)")
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

    @Test("Reset re-docks detached panels but keeps the default float (Text Map)")
    func resetClearsDetached() {
        let store = makeStore()
        store.detach(.map)
        store.detach(.channels)
        store.resetToDefault()
        #expect(store.detached.isEmpty)
        #expect(store.floating == LayoutStore.defaultFloating)
        #expect(!store.layout.contains(.asciiMap), "the default-float Text Map stays out of the dock")
    }

    // MARK: - Floating miniwindows

    @Test("The Text Map floats by default and isn't in the dock")
    func textMapFloatsByDefault() {
        let store = makeStore()
        #expect(store.isFloating(.asciiMap))
        #expect(!store.layout.contains(.asciiMap))
        #expect(store.isVisible(.asciiMap))
    }

    @Test("Floating the Text Map removes it from the dock; docking returns it")
    func floatAndDock() {
        let store = makeStore()
        // The Text Map floats by default; dock it, then float it again.
        store.dockFloating(.asciiMap)
        #expect(!store.isFloating(.asciiMap))
        #expect(store.layout.contains(.asciiMap))
        store.float(.asciiMap)
        #expect(store.isFloating(.asciiMap))
        #expect(!store.layout.contains(.asciiMap))
    }

    @Test("Only the Text Map may float; other panels are rejected")
    func onlyTextMapFloats() {
        let store = makeStore()
        store.float(.channels)
        #expect(!store.isFloating(.channels))
        #expect(store.layout.contains(.channels)) // stays docked
    }

    @Test("Re-showing a hidden panel restores its prior dock position")
    func reShowRestoresPosition() {
        let store = makeStore()
        // map sits above the [hunt, asciiMap] tab group in the default layout.
        #expect(store.layout.anchorSlot(for: .map)?.anchor == .hunt)
        store.toggle(.map) // hide
        #expect(!store.layout.contains(.map))
        store.toggle(.map) // re-show → restored to its remembered slot
        #expect(store.layout.contains(.map))
        #expect(store.layout.anchorSlot(for: .map)?.anchor == .hunt)
        #expect(store.layout.anchorSlot(for: .map)?.zone == .top)
    }

    @Test("Toggling a floating panel off hides it")
    func toggleHidesFloating() {
        let store = makeStore()
        store.toggle(.asciiMap) // floating by default → hide
        #expect(!store.isFloating(.asciiMap))
        #expect(!store.isVisible(.asciiMap))
    }

    @Test("Detaching a floating panel moves it to its own window")
    func detachFromFloating() {
        let store = makeStore()
        store.detach(.asciiMap) // was floating
        #expect(store.isDetached(.asciiMap))
        #expect(!store.isFloating(.asciiMap))
    }

    // MARK: - Presets

    @Test("Saving a preset captures the current layout + floating panels")
    func savePresetCaptures() {
        let store = makeStore()
        // The Text Map floats by default → the preset should record it.
        store.savePreset(named: "Mine")
        #expect(store.presets.map(\.name) == ["Mine"])
        #expect(Set(store.presets[0].floating).contains(.asciiMap))
    }

    @Test("Applying a preset restores its layout and floats, and re-docks detached")
    func applyPresetRestores() {
        let store = makeStore()
        store.savePreset(named: "Base") // default arrangement (Text Map floats)
        store.detach(.map)
        store.applyPreset(store.presets[0])
        #expect(store.detached.isEmpty, "apply returns detached panels to the dock")
        #expect(store.isFloating(.asciiMap), "preset's floating set is restored")
        #expect(store.layout.contains(.map), "the detached map is back in the dock")
    }

    @Test("Deleting a preset removes it")
    func deletePreset() {
        let store = makeStore()
        store.savePreset(named: "Temp")
        store.deletePreset(named: "Temp")
        #expect(store.presets.isEmpty)
    }

    @Test("Presets persist across store instances (same presets key)")
    func presetsPersist() {
        let key = "test.presets.\(UUID().uuidString)"
        let first = LayoutStore(persistenceKey: "test.layout.\(UUID().uuidString)", presetsKey: key)
        first.savePreset(named: "Shared")
        let second = LayoutStore(persistenceKey: "test.layout.\(UUID().uuidString)", presetsKey: key)
        #expect(second.presets.map(\.name) == ["Shared"])
    }
}
