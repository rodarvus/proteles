import Foundation

struct MarketCommandCaptureState {
    var kind: MarketCapture.Kind
    var lines: [Line] = []
    var borderCount = 0
    var sawAuctionMetadata = false
    var lineLimit = 120
}

extension SessionController {
    func armMarketCapture(for command: String) {
        guard marketCaptureEnabled, let kind = MarketCommandParser.captureKind(for: command) else { return }
        let capture = MarketCommandCaptureState(kind: kind)
        if marketTagCaptureActive || marketCommandCapture != nil {
            queuedMarketCommandCaptures.append(capture)
        } else {
            marketCommandCapture = capture
        }
    }

    func captureMarketLine(_ line: Line) -> Bool {
        if captureMarketTaggedLine(line) { return true }
        guard marketCommandCapture != nil else { return false }
        return captureMarketCommandLine(line)
    }

    private func captureMarketTaggedLine(_ line: Line) -> Bool {
        if marketTagCaptureActive {
            if MarketParser.isCloseTag(line.text) {
                marketTagCaptureActive = false
                let variant = MarketParser.listVariant(from: marketTagCaptureBuffer)
                marketCapturesContinuation.yield(.init(
                    kind: .list(variant),
                    lines: marketTagCaptureBuffer
                ))
                marketTagCaptureBuffer = []
                startNextMarketCommandCaptureIfNeeded()
                return true
            }
            marketTagCaptureBuffer.append(line)
            return true
        }
        if MarketParser.isOpenTag(line.text) {
            marketTagCaptureActive = true
            marketTagCaptureBuffer = []
            return true
        }
        return false
    }

    private func captureMarketCommandLine(_ line: Line) -> Bool {
        guard var capture = marketCommandCapture else { return false }
        if isPromptLike(line.text) {
            if capture.lines.isEmpty {
                marketCommandCapture = capture
                return true
            }
            publishMarketCommandCapture(capture)
            marketCommandCapture = nil
            startNextMarketCommandCaptureIfNeeded()
            return true
        }
        capture.lines.append(line)
        if line.text.hasPrefix("+---") { capture.borderCount += 1 }
        if isAuctionMetadataLine(line.text) { capture.sawAuctionMetadata = true }
        if isComplete(capture) || capture.lines.count >= capture.lineLimit {
            publishMarketCommandCapture(capture)
            marketCommandCapture = nil
            startNextMarketCommandCaptureIfNeeded()
        } else {
            marketCommandCapture = capture
        }
        return true
    }

    private func isComplete(_ capture: MarketCommandCaptureState) -> Bool {
        switch capture.kind {
        case .detail:
            capture.sawAuctionMetadata && capture.lines.last?.text.hasPrefix("+---") == true
        case .bidResult, .history, .list:
            false
        }
    }

    private func publishMarketCommandCapture(_ capture: MarketCommandCaptureState) {
        let lines = capture.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }
        marketCapturesContinuation.yield(.init(kind: capture.kind, lines: lines))
    }

    private func startNextMarketCommandCaptureIfNeeded() {
        guard marketCommandCapture == nil, !queuedMarketCommandCaptures.isEmpty else { return }
        marketCommandCapture = queuedMarketCommandCaptures.removeFirst()
    }

    private func isPromptLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]>")
    }

    private func isAuctionMetadataLine(_ text: String) -> Bool {
        text.contains("| Market Item Number")
            || text.contains("| Item is being sold by")
            || text.contains("| Auction will end in")
            || text.contains("| Current bid")
    }
}
