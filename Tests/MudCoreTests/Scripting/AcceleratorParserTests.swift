@testable import MudCore
import Testing

@Suite("AcceleratorParser — MUSHclient key strings → KeyChord")
struct AcceleratorParserTests {
    @Test("modifier + letter")
    func modifierLetter() {
        let chord = AcceleratorParser.chord(from: "Ctrl+P")
        #expect(chord?.keyCode == 35) // kVK_ANSI_P
        #expect(chord?.modifiers == .control)
        #expect(chord?.isKeypad == false)
        #expect(chord?.isFunctionKey == false)
    }

    @Test("multiple modifiers (case/spacing-insensitive)")
    func multipleModifiers() {
        let chord = AcceleratorParser.chord(from: " alt + Shift + a ")
        #expect(chord?.keyCode == 0) // kVK_ANSI_A
        #expect(chord?.modifiers == [.option, .shift])
    }

    @Test("function key")
    func functionKey() {
        let chord = AcceleratorParser.chord(from: "F4")
        #expect(chord?.keyCode == KeyCode.f4)
        #expect(chord?.isFunctionKey == true)
        #expect(chord?.modifiers.isEmpty == true)
    }

    @Test("numpad key with modifier")
    func numpad() {
        let chord = AcceleratorParser.chord(from: "Ctrl+Numpad5")
        #expect(chord?.keyCode == KeyCode.keypad5)
        #expect(chord?.isKeypad == true)
        #expect(chord?.modifiers == .control)
    }

    @Test("Win maps to command; digit key")
    func winAndDigit() {
        let chord = AcceleratorParser.chord(from: "Win+1")
        #expect(chord?.keyCode == 18) // kVK_ANSI_1
        #expect(chord?.modifiers == .command)
    }

    @Test("unknown key or modifier returns nil (no guessing)")
    func unknown() {
        #expect(AcceleratorParser.chord(from: "Ctrl+Frobnicate") == nil)
        #expect(AcceleratorParser.chord(from: "Hyper+P") == nil)
        #expect(AcceleratorParser.chord(from: "") == nil)
    }
}
