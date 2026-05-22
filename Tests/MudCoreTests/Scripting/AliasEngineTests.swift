import Foundation
@testable import MudCore
import Testing

@Suite("AliasEngine — matching")
struct AliasEngineTests {
    @Test("A matching alias expands its send text from captures")
    func expand() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .wildcard("gg *"), sendText: "get %1 from corpse"))
        let firings = engine.match("gg sword")
        #expect(firings.count == 1)
        #expect(firings.first?.send == "get sword from corpse")
        #expect(firings.first?.target == .world)
    }

    @Test("No matching alias yields no firings")
    func noMatch() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .exact("xyzzy"), sendText: "magic"))
        #expect(engine.match("hello").isEmpty)
    }

    @Test("Default is stop-after-first-match (one intent per line)")
    func stopsAfterFirst() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .substring("x"), sequence: 100, sendText: "first"))
        try engine.add(Alias(pattern: .substring("x"), sequence: 200, sendText: "second"))
        #expect(engine.match("x").map(\.send) == ["first"])
    }

    @Test("keepEvaluating lets several aliases fire")
    func keepEvaluating() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .substring("x"), sequence: 100, keepEvaluating: true, sendText: "a"))
        try engine.add(Alias(pattern: .substring("x"), sequence: 200, sendText: "b"))
        #expect(engine.match("x").map(\.send) == ["a", "b"])
    }

    @Test("Targets are carried on the firing")
    func targets() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .exact("run"), sendText: "n;n;e", sendTo: .execute))
        #expect(engine.match("run").first?.target == .execute)
    }

    @Test("Disabled aliases and groups don't fire; one-shots self-remove")
    func lifecycle() throws {
        var engine = AliasEngine()
        try engine.add(Alias(pattern: .exact("once"), oneShot: true, sendText: "boom"))
        #expect(engine.match("once").count == 1)
        #expect(engine.match("once").isEmpty)
        #expect(engine.allAliases.isEmpty)

        let id = UUID()
        try engine.add(Alias(id: id, pattern: .exact("k"), sendText: "kill"))
        engine.setEnabled(false, id: id)
        #expect(engine.match("k").isEmpty)
    }

    @Test("Invalid regex throws")
    func invalidRegex() {
        var engine = AliasEngine()
        #expect(throws: AliasEngine.AliasError.self) {
            try engine.add(Alias(pattern: .regex("(bad")))
        }
    }
}

@Suite("ScriptEngine — input expansion")
struct ScriptEngineExpandInputTests {
    @Test("Unmatched input is sent verbatim")
    func passthrough() async throws {
        let engine = try ScriptEngine()
        #expect(await engine.expandInput("look") == [.send("look")])
    }

    @Test("A world alias rewrites the command")
    func worldAlias() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .wildcard("gg *"), sendText: "get %1 from corpse"))
        #expect(await engine.expandInput("gg gold") == [.send("get gold from corpse")])
    }

    @Test("An execute alias re-expands through aliases")
    func executeAlias() async throws {
        let engine = try ScriptEngine()
        // "run" expands (via execute) to "go", which is itself an alias.
        try await engine.addAlias(Alias(pattern: .exact("run"), sendText: "go", sendTo: .execute))
        try await engine.addAlias(Alias(pattern: .exact("go"), sendText: "north"))
        #expect(await engine.expandInput("run") == [.send("north")])
    }

    @Test("Execute recursion is bounded")
    func executeRecursionGuard() async throws {
        let engine = try ScriptEngine()
        // A self-referential execute alias must terminate, not hang.
        try await engine.addAlias(Alias(pattern: .exact("loop"), sendText: "loop", sendTo: .execute))
        let effects = await engine.expandInput("loop")
        #expect(effects.contains { effect in
            if case .note(let text, _, _) = effect { return text.contains("recursion limit") }
            return false
        })
    }

    @Test("A script alias runs Lua with captures")
    func scriptAlias() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(
            pattern: .wildcard("greet *"),
            sendText: "proteles.send('say hello ' .. matches[1])",
            sendTo: .script
        ))
        #expect(await engine.expandInput("greet Bob") == [.send("say hello Bob")])
    }

    @Test("An output alias echoes locally")
    func outputAlias() async throws {
        let engine = try ScriptEngine()
        try await engine.addAlias(Alias(pattern: .exact("hi"), sendText: "(waves)", sendTo: .output))
        #expect(await engine.expandInput("hi") == [.echo("(waves)")])
    }
}
