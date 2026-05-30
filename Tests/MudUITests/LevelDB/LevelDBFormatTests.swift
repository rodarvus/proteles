import MudCore
@testable import MudUI
import Testing

/// The compact human formatting the leveldb panels use for big counts/durations.
@Suite("LevelDBFormat — compact numbers")
struct LevelDBFormatTests {
    @Test("compact counts")
    func compact() {
        #expect(LevelDBFormat.compact(950) == "950")
        #expect(LevelDBFormat.compact(9999) == "9,999")
        #expect(LevelDBFormat.compact(11500) == "11.5k")
        #expect(LevelDBFormat.compact(11_219_400) == "11.2M")
        #expect(LevelDBFormat.compact(118_534_077) == "119M")
        #expect(LevelDBFormat.compact(2_000_000_000) == "2.0B")
    }

    @Test("grouped + duration")
    func grouped() {
        #expect(LevelDBFormat.grouped(1_234_567) == "1,234,567")
        #expect(LevelDBFormat.duration(400) == "6:40")
        #expect(LevelDBFormat.duration(3725) == "1:02:05")
        #expect(LevelDBFormat.duration(-1) == "—")
    }
}
