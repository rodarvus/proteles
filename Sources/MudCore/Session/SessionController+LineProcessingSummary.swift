import Foundation

struct LineProcessingSummary: Equatable {
    var displayed = 0
    var gagged = 0
    var effects = 0

    mutating func add(_ other: LineProcessingSummary) {
        displayed += other.displayed
        gagged += other.gagged
        effects += other.effects
    }
}
