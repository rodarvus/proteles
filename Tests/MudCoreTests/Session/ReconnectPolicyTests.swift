import Foundation
@testable import MudCore
import Testing

@Suite("ReconnectPolicy — backoff")
struct ReconnectPolicyTests {
    @Test("First attempt waits the base delay")
    func firstAttemptIsBase() {
        let policy = ReconnectPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30), multiplier: 2)
        #expect(policy.delay(forAttempt: 1) == .seconds(1))
    }

    @Test("Delay doubles each attempt until the cap")
    func exponentialGrowth() {
        let policy = ReconnectPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30), multiplier: 2)
        #expect(policy.delay(forAttempt: 2) == .seconds(2))
        #expect(policy.delay(forAttempt: 3) == .seconds(4))
        #expect(policy.delay(forAttempt: 4) == .seconds(8))
        #expect(policy.delay(forAttempt: 5) == .seconds(16))
    }

    @Test("Delay is clamped to maxDelay")
    func clampedToMax() {
        let policy = ReconnectPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30), multiplier: 2)
        // 2^5 = 32 > 30, so it caps.
        #expect(policy.delay(forAttempt: 6) == .seconds(30))
        #expect(policy.delay(forAttempt: 20) == .seconds(30))
    }

    @Test("Attempts below 1 are treated as the first attempt")
    func nonPositiveAttempt() {
        let policy = ReconnectPolicy(baseDelay: .seconds(2), maxDelay: .seconds(30), multiplier: 2)
        #expect(policy.delay(forAttempt: 0) == .seconds(2))
        #expect(policy.delay(forAttempt: -5) == .seconds(2))
    }

    @Test("Presets carry the expected enabled flag")
    func presets() {
        #expect(!ReconnectPolicy.disabled.isEnabled)
        #expect(ReconnectPolicy.standard.isEnabled)
    }
}
