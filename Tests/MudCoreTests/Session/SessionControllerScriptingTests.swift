import Foundation
@testable import MudCore
import Testing

// End-to-end scripting: a trigger on a received line sends a command to the
// MUD, and a gag trigger removes a line from the scrollback — exercised over
// the loopback listener.

private actor ByteSink {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }

    func snapshot() -> [UInt8] {
        bytes
    }
}

@Suite("SessionController — scripting", .serialized)
struct SessionControllerScriptingTests {
    private func waitFor(
        _ needle: [UInt8],
        in sink: ByteSink,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await Data(sink.snapshot()).range(of: Data(needle)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("A trigger on a received line sends a command to the MUD")
    func triggerSendsCommand() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = Task { for await chunk in listener.received {
            await sink.append(chunk)
        } }

        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .wildcard("* arrives."), sendText: "kill %1"))
        let controller = SessionController(scriptEngine: engine)
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await listener.send(Array("a goblin arrives.\n".utf8))

        #expect(await waitFor(Array("kill a goblin\r\n".utf8), in: sink))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("A typed alias is expanded before being sent to the MUD")
    func aliasExpandsUserInput() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = Task { for await chunk in listener.received {
            await sink.append(chunk)
        } }

        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .wildcard("gg *"), sendText: "get %1 from corpse"))
        let controller = SessionController(scriptEngine: engine)
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await controller.send("gg sword")
        #expect(await waitFor(Array("get sword from corpse\r\n".utf8), in: sink))

        // An un-aliased command passes through verbatim.
        try await controller.send("look")
        #expect(await waitFor(Array("look\r\n".utf8), in: sink))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("A timer fires on its schedule and sends to the MUD")
    func timerSendsCommand() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let sink = ByteSink()
        let drainTask = Task { for await chunk in listener.received {
            await sink.append(chunk)
        } }

        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        try await controller.addTimer(MudTimer(schedule: .after(0.05), action: .send("save")))
        #expect(await waitFor(Array("save\r\n".utf8), in: sink))

        await controller.disconnect()
        await listener.stop()
        drainTask.cancel()
    }

    @Test("A gag trigger keeps the matched line out of the scrollback")
    func gagTriggerDropsLine() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()

        let engine = try ScriptEngine()
        try await engine.addTrigger(Trigger(pattern: .substring("SPAM"), gag: true))
        let controller = SessionController(scriptEngine: engine)
        try await controller.connect(to: .init(host: "127.0.0.1", port: port))
        await listener.waitForConnection()

        let stream = await controller.scrollbackStore.subscribe()
        try await listener.send(Array("SPAM advertisement\nreal content\n".utf8))

        // The first line surfacing should be the non-gagged one.
        var firstLine: Line?
        for await line in stream {
            firstLine = line
            break
        }
        #expect(firstLine?.text == "real content")

        await controller.disconnect()
        await listener.stop()
    }

    @Test("ColourNote segments render as one styled run per segment")
    func colourNoteRendersPerSegmentRuns() {
        let line = SessionController.colourNoteLine([
            NoteSegment(text: "a", foreground: "white", background: nil),
            NoteSegment(text: "bb", foreground: "red", background: "blue"),
            NoteSegment(text: "c", foreground: nil, background: nil)
        ])
        #expect(line.text == "abbc")
        // Two runs: the white "a" (0..<1) and the red-on-blue "bb" (1..<3).
        // The default-styled "c" contributes no run.
        #expect(line.runs.count == 2)
        #expect(line.runs[0].utf16Range == 0..<1)
        #expect(line.runs[0].style.foreground == .rgb(red: 0xFF, green: 0xFF, blue: 0xFF))
        #expect(line.runs[1].utf16Range == 1..<3)
        #expect(line.runs[1].style.foreground == .rgb(red: 0xFF, green: 0x00, blue: 0x00))
        #expect(line.runs[1].style.background == .rgb(red: 0x00, green: 0x00, blue: 0xFF))
    }

    @Test("ColourNote resolves #RRGGBB hex colours to RGB runs")
    func colourNoteHexColour() {
        let line = SessionController.colourNoteLine([
            NoteSegment(text: "x", foreground: "#FF8800", background: nil)
        ])
        #expect(line.runs.count == 1)
        #expect(line.runs[0].style.foreground == .rgb(red: 0xFF, green: 0x88, blue: 0x00))
    }

    @Test("ColourNote resolves MUSHclient's extended named colours (e.g. orange)")
    func colourNoteExtendedNamedColour() {
        // "orange" (0xFFA500) is not one of the 8 ANSI names, so before the
        // 148-name table fallback it rendered colourless; now it's a real RGB run.
        let line = SessionController.colourNoteLine([
            NoteSegment(text: "warn", foreground: "orange", background: "dodgerblue")
        ])
        #expect(line.runs.count == 1)
        #expect(line.runs[0].style.foreground == .rgb(red: 0xFF, green: 0xA5, blue: 0x00))
        #expect(line.runs[0].style.background == .rgb(red: 0x1E, green: 0x90, blue: 0xFF))
        // The 8 basic names are MUSHclient colour names too: "red" is bright
        // #FF0000, not the theme's normal/dim ANSI red.
        let basic = SessionController.colourNoteLine([
            NoteSegment(text: "x", foreground: "red", background: nil)
        ])
        #expect(basic.runs[0].style.foreground == .rgb(red: 0xFF, green: 0x00, blue: 0x00))
        // A truly unknown name stays unstyled (no run).
        let unknown = SessionController.colourNoteLine([
            NoteSegment(text: "x", foreground: "notacolour", background: nil)
        ])
        #expect(unknown.runs.isEmpty)
    }
}
