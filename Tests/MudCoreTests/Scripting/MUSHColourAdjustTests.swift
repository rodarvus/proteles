@testable import MudCore
import Testing

/// `AdjustColour` — verified against MUSHclient's `AdjustColour` + `CColor` HLS
/// math. Expected values were independently reproduced with the same IEEE-754
/// `double` ops, so they are byte-exact, not eyeballed. Colours are COLORREFs
/// (red low byte).
@Suite("MUSHColour — AdjustColour")
struct MUSHColourAdjustTests {
    @Test("invert is exact per channel")
    func invert() {
        #expect(MUSHColour.adjustColour(0x0000FF, method: 1) == 0xFFFF00) // red -> cyan
        #expect(MUSHColour.adjustColour(0xFFFFFF, method: 1) == 0x000000) // white -> black
        #expect(MUSHColour.adjustColour(0x000000, method: 1) == 0xFFFFFF) // black -> white
    }

    @Test("no-op and unknown methods return the input (masked to 24-bit)")
    func noOp() {
        #expect(MUSHColour.adjustColour(0x123456, method: 0) == 0x123456)
        #expect(MUSHColour.adjustColour(0x123456, method: 99) == 0x123456)
        #expect(MUSHColour.adjustColour(0xFF12_3456, method: 0) == 0x123456) // high byte dropped
    }

    @Test("lighter/darker step luminance (grey, the sat<=0 path)")
    func luminance() {
        #expect(MUSHColour.adjustColour(0x808080, method: 3) == 0x7B7B7B) // darker
        #expect(MUSHColour.adjustColour(0x808080, method: 2) == 0x858585) // lighter
    }

    @Test("more/less colour step saturation (the full HLS path)")
    func saturation() {
        #expect(MUSHColour.adjustColour(0x404040, method: 5) == 0x3D3D43) // more colour, hue 0
        #expect(MUSHColour.adjustColour(0x0000FF, method: 4) == 0x0606F9) // less colour (red desaturates)
    }
}

/// `CreateGUID` / `GetUniqueID` — the contract is format + uniqueness (the value
/// is random), so we assert the shape and that successive calls differ.
@Suite("ScriptIdentifiers — CreateGUID / GetUniqueID")
struct ScriptIdentifiersTests {
    @Test("CreateGUID is an uppercase dashed GUID")
    func createGUID() {
        let guid = ScriptIdentifiers.createGUID()
        let pattern = "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
        #expect(guid.range(of: pattern, options: .regularExpression) != nil, "bad GUID: \(guid)")
        #expect(ScriptIdentifiers.createGUID() != guid)
    }

    @Test("GetUniqueID is 24 lowercase hex chars")
    func uniqueID() {
        let id = ScriptIdentifiers.uniqueID()
        #expect(id.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil, "bad id: \(id)")
        #expect(ScriptIdentifiers.uniqueID() != id)
    }
}

/// The three reached through the generic compat shim (the plugin path).
@Suite("AdjustColour / CreateGUID / GetUniqueID via the shim")
struct ColourAdjustShimTests {
    @Test("the shim globals are wired to the native implementations")
    func shimGlobals() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim()
        // AdjustColour(red, invert) -> cyan COLORREF = 0xFFFF00 = 16776960.
        #expect(await engine.evaluateConsole("AdjustColour(255, 1)")
            == [.note(text: "lua: = 16776960", foreground: "cyan", background: nil)])
        // Right-length id strings (GUID 36 incl. dashes, unique id 24).
        #expect(await engine.evaluateConsole("string.len(CreateGUID())")
            == [.note(text: "lua: = 36", foreground: "cyan", background: nil)])
        #expect(await engine.evaluateConsole("string.len(GetUniqueID())")
            == [.note(text: "lua: = 24", foreground: "cyan", background: nil)])
    }
}
