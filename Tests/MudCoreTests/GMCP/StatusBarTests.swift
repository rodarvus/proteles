import Foundation
@testable import MudCore
import Testing

@Suite("Status bar model")
struct StatusBarTests {
    // MARK: - Number overlay modes (request: no text / raw number / percentage)

    @Test("overlay text honours the number mode")
    func overlayModes() {
        #expect(StatusBarFormat.overlay(mode: .none, current: 2093, max: 2529) == nil)
        #expect(StatusBarFormat.overlay(mode: .number, current: 2093, max: 2529) == "2093")
        #expect(StatusBarFormat.overlay(mode: .percentage, current: 2093, max: 2529) == "83%")
    }

    @Test("percentage rounds and clamps; guards a zero max")
    func percentageEdges() {
        #expect(StatusBarFormat.overlay(mode: .percentage, current: 1, max: 2) == "50%")
        #expect(StatusBarFormat.overlay(mode: .percentage, current: 5, max: 0) == nil)
        #expect(StatusBarFormat.overlay(mode: .percentage, current: 999, max: 100) == "100%")
    }

    @Test("fraction clamps to 0…1 and guards a zero max")
    func fractionClamps() {
        #expect(StatusBarFormat.fraction(current: 2093, max: 2529) == 2093.0 / 2529.0)
        #expect(StatusBarFormat.fraction(current: 5, max: 0) == 0)
        #expect(StatusBarFormat.fraction(current: 300, max: 100) == 1)
    }

    // MARK: - Alignment bar (marker position + tier colour)

    @Test("align fraction maps -2500…2500 onto 0…1 with neutral at centre")
    func alignFraction() {
        #expect(StatusBarFormat.alignFraction(0) == 0.5)
        #expect(StatusBarFormat.alignFraction(2500) == 1)
        #expect(StatusBarFormat.alignFraction(-2500) == 0)
        #expect(StatusBarFormat.alignFraction(-9999) == 0) // clamped
    }

    @Test("align tier matches the reference boundaries (±875)")
    func alignTier() {
        #expect(StatusBarFormat.alignTier(1000) == .good)
        #expect(StatusBarFormat.alignTier(875) == .good)
        #expect(StatusBarFormat.alignTier(-1000) == .evil)
        #expect(StatusBarFormat.alignTier(-875) == .evil)
        #expect(StatusBarFormat.alignTier(0) == .neutral)
        #expect(StatusBarFormat.alignTier(500) == .neutral)
    }

    // MARK: - Config

    @Test("isEmpty only when every bar is off")
    func configEmpty() {
        #expect(StatusBarConfig().isEmpty == false)
        #expect(StatusBarConfig().showTicks == true) // quarter marks on by default
        var off = StatusBarConfig(
            showHealth: false,
            showMana: false,
            showMoves: false,
            showTNL: false,
            showEnemy: false,
            showAlign: false
        )
        #expect(off.isEmpty == true)
        off.showEnemy = true
        #expect(off.isEmpty == false)
    }

    // MARK: - Default colours (the BGR→RGB correction)

    /// Parse `#RRGGBB` → (red, green, blue).
    private struct RGB { let red: Int; let green: Int; let blue: Int }
    private func rgb(_ hex: String) -> RGB {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        return RGB(red: Int((value >> 16) & 0xFF), green: Int((value >> 8) & 0xFF), blue: Int(value & 0xFF))
    }

    @Test("default bar colours match the corrected (RGB) semantics, not the BGR mix-up")
    func defaultColourSemantics() {
        let colors = StatusBarColors()
        let health = rgb(colors.health), mana = rgb(colors.mana)
        let moves = rgb(colors.moves), enemy = rgb(colors.enemy)
        // Health is green-dominant.
        #expect(health.green > health.red && health.green > health.blue)
        // Mana is blue-dominant (the bug had it orange — red-dominant).
        #expect(mana.blue > mana.red && mana.blue > mana.green, "mana should be blue: \(colors.mana)")
        // Moves is yellow (high red + green, low blue).
        #expect(
            moves.red > 150 && moves.green > 150 && moves.blue < 100,
            "moves should be yellow: \(colors.moves)"
        )
        // Enemy is red-dominant.
        #expect(enemy.red > enemy.green && enemy.red > enemy.blue, "enemy should be red: \(colors.enemy)")
    }

    // MARK: - GMCP decode

    @Test("char.base decodes perlevel (the TNL bar's denominator)")
    func perlevelDecodes() throws {
        let json = #"{"name":"Tester","class":"Mage","perlevel":12000}"#
        let base = try JSONDecoder().decode(CharBase.self, from: Data(json.utf8))
        #expect(base.perlevel == 12000)
        // Absent perlevel still decodes (older payloads).
        let bare = try JSONDecoder().decode(CharBase.self, from: Data(#"{"name":"X"}"#.utf8))
        #expect(bare.perlevel == nil)
    }
}
