import Foundation

/// The number of main-output lines retained in memory.
///
/// `storedValue` deliberately maps `0` to ``unlimited`` so the preference is
/// compatible with the convention used by MUD clients that expose an
/// unbounded scrollback option. Unlimited means Proteles performs no proactive
/// eviction; the process remains subject to macOS memory pressure.
public enum ScrollbackLimit: Sendable, Equatable {
    public static let defaultLineCount = 100_000

    case limited(Int)
    case unlimited

    public init(storedValue: Int) {
        if storedValue == 0 {
            self = .unlimited
        } else if storedValue > 0 {
            self = .limited(storedValue)
        } else {
            self = .limited(Self.defaultLineCount)
        }
    }

    public var storedValue: Int {
        switch self {
        case .limited(let lineCount): lineCount
        case .unlimited: 0
        }
    }

    public var lineCount: Int? {
        switch self {
        case .limited(let lineCount): lineCount
        case .unlimited: nil
        }
    }

    public var diagnosticLabel: String {
        switch self {
        case .limited(let lineCount): "limited-\(lineCount)"
        case .unlimited: "unlimited"
        }
    }
}
