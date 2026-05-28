import MudCore
import SwiftUI

/// A "Test" affordance for the trigger/alias editors: type a sample line and
/// see live whether the pattern matches and what it captures. Pure UI over
/// ``PatternTester`` (no engine state).
struct PatternTestView: View {
    let pattern: TriggerPattern
    let caseSensitive: Bool
    @State private var sample = ""

    var body: some View {
        TextField("Sample line to test", text: $sample)
            .font(.body.monospaced())
        resultView(PatternTester.test(pattern, caseSensitive: caseSensitive, against: sample))
    }

    @ViewBuilder
    private func resultView(_ result: PatternTestResult) -> some View {
        switch result {
        case .invalidPattern:
            caption(
                "Fix the pattern above to test it.",
                systemImage: "exclamationmark.triangle",
                tint: .secondary
            )
        case .empty:
            caption("Type a sample line to check the pattern.", systemImage: "text.cursor", tint: .secondary)
        case .noMatch:
            caption("No match.", systemImage: "xmark.circle", tint: .secondary)
        case .match(let wildcards, let named):
            VStack(alignment: .leading, spacing: 4) {
                caption("Matches.", systemImage: "checkmark.circle.fill", tint: .green)
                ForEach(Array(wildcards.enumerated()), id: \.offset) { index, value in
                    captureRow("%\(index)", value)
                }
                ForEach(named.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    captureRow(key, value)
                }
            }
        }
    }

    private func caption(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private func captureRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value.isEmpty ? "(empty)" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }
}

extension TriggerPattern {
    /// Whether this pattern fails to compile (drives the editors' inline red
    /// validation hint). Checked against an empty line so it's independent of
    /// any sample text.
    func isInvalid(caseSensitive: Bool) -> Bool {
        if case .invalidPattern = PatternTester.test(self, caseSensitive: caseSensitive, against: "") {
            return true
        }
        return false
    }
}
