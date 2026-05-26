import Foundation
@testable import MudCore
import Testing

@Suite("TickTimer — comm.tick → updateTick effect")
struct TickTimerTests {
    @Test("comm.tick emits an updateTick anchor near now")
    func commTickEmitsUpdateTick() {
        var plugin = TickTimer()
        let effects = plugin.onGMCP(package: "comm.tick", json: #"{"ctime":1779752147}"#)
        guard effects.count == 1, case .updateTick(let date) = effects[0], let date else {
            Issue.record("expected one .updateTick(date) effect, got \(effects)")
            return
        }
        #expect(abs(date.timeIntervalSinceNow) < 5) // anchored at receipt (~now)
    }

    @Test("Package name is matched case-insensitively")
    func caseInsensitive() {
        var plugin = TickTimer()
        #expect(!plugin.onGMCP(package: "Comm.Tick", json: "{}").isEmpty)
    }

    @Test("Other GMCP packages produce no effects")
    func ignoresOtherPackages() {
        var plugin = TickTimer()
        #expect(plugin.onGMCP(package: "char.vitals", json: #"{"hp":1}"#).isEmpty)
        #expect(plugin.onGMCP(package: "comm.channel", json: "{}").isEmpty)
    }

    @Test("Registered native plugin is enabled by default and routes comm.tick")
    func registryRoutesWhenEnabled() {
        var registry = NativePluginRegistry()
        _ = registry.register(TickTimer())
        // Enabled → comm.tick yields an updateTick.
        #expect(!registry.onGMCP(package: "comm.tick", json: "{}").isEmpty)
        // Disabled → the host stops routing comm.tick, so the readout self-hides.
        _ = registry.setEnabled(false, id: "com.proteles.ticktimer")
        #expect(registry.onGMCP(package: "comm.tick", json: "{}").isEmpty)
    }
}
