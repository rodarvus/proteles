import Foundation

public struct MarketCapture: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case list(MarketListVariant)
        case detail(itemNumber: Int?)
        case history(itemNumber: Int?)
        case bidResult(itemNumber: Int?, proxy: Bool)
    }

    public var kind: Kind
    public var lines: [Line]

    public init(kind: Kind, lines: [Line]) {
        self.kind = kind
        self.lines = lines
    }
}

public enum MarketListVariant: String, Sendable, Equatable, CaseIterable {
    case standard
    case sellers
    case amounts
    case filtered
}

public struct MarketItem: Identifiable, Sendable, Equatable {
    public var id: Int {
        number
    }

    public var number: Int
    public var name: String
    public var level: Int?
    public var type: String
    public var lastBid: Int?
    public var bidCount: Int?
    public var timeLeft: String?
    public var seller: String?
    public var lastBidder: String?
    public var buyout: Int?
    public var isShowcase: Bool
    public var hasBuyout: Bool
    public var isHighBidder: Bool
    public var nameLine: Line?

    public init(
        number: Int,
        name: String,
        level: Int?,
        type: String,
        lastBid: Int? = nil,
        bidCount: Int? = nil,
        timeLeft: String? = nil,
        seller: String? = nil,
        lastBidder: String? = nil,
        buyout: Int? = nil,
        isShowcase: Bool = false,
        hasBuyout: Bool = false,
        isHighBidder: Bool = false,
        nameLine: Line? = nil
    ) {
        self.number = number
        self.name = name
        self.level = level
        self.type = type
        self.lastBid = lastBid
        self.bidCount = bidCount
        self.timeLeft = timeLeft
        self.seller = seller
        self.lastBidder = lastBidder
        self.buyout = buyout
        self.isShowcase = isShowcase
        self.hasBuyout = hasBuyout
        self.isHighBidder = isHighBidder
        self.nameLine = nameLine
    }
}

public struct MarketDetailField: Sendable, Equatable, Identifiable {
    public var id: String {
        label
    }

    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct MarketDetail: Sendable, Equatable {
    public var itemNumber: Int?
    public var title: String
    public var fields: [MarketDetailField]
    public var rawLines: [Line]
    public var displayLines: [Line]

    public init(
        itemNumber: Int?,
        title: String,
        fields: [MarketDetailField],
        rawLines: [Line],
        displayLines: [Line]
    ) {
        self.itemNumber = itemNumber
        self.title = title
        self.fields = fields
        self.rawLines = rawLines
        self.displayLines = displayLines
    }
}

public struct MarketBidHistoryRow: Identifiable, Sendable, Equatable {
    public var id: String {
        "\(bidder)|\(amount ?? -1)|\(time)|\(isProxy)"
    }

    public var bidder: String
    public var amount: Int?
    public var time: String
    public var isProxy: Bool

    public init(bidder: String, amount: Int?, time: String, isProxy: Bool) {
        self.bidder = bidder
        self.amount = amount
        self.time = time
        self.isProxy = isProxy
    }
}

public struct MarketBidHistory: Sendable, Equatable {
    public var itemNumber: Int?
    public var title: String
    public var rows: [MarketBidHistoryRow]
    public var rawLines: [Line]

    public init(itemNumber: Int?, title: String, rows: [MarketBidHistoryRow], rawLines: [Line]) {
        self.itemNumber = itemNumber
        self.title = title
        self.rows = rows
        self.rawLines = rawLines
    }
}

public enum MarketCommandParser {
    public static func captureKind(for command: String) -> MarketCapture.Kind? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first?.lowercased(), first == "lbid" || first == "market" else {
            return nil
        }

        let normalized = normalizeMarketTokens(tokens)
        if normalized.contains("history"), let item = firstNumber(in: normalized) {
            return .history(itemNumber: item)
        }
        if normalized.contains("confirm"), let item = firstNumber(in: normalized) {
            return .bidResult(itemNumber: item, proxy: normalized.contains("proxy"))
        }
        if normalized.contains("proxy"), let item = firstNumber(in: normalized) {
            return .bidResult(itemNumber: item, proxy: true)
        }
        let hasBidAmount = normalized.dropFirst(2).contains { parseBidAmount($0) != nil }
        if first == "lbid", let item = firstNumber(in: normalized), normalized.count >= 3, hasBidAmount {
            return .bidResult(itemNumber: item, proxy: false)
        }
        if let item = firstNumber(in: normalized), normalized.count == itemOnlyCount(for: normalized) {
            return .detail(itemNumber: item)
        }
        return nil
    }

    private static func normalizeMarketTokens(_ tokens: [String]) -> [String] {
        func keep(_ token: String) -> Bool {
            token.lowercased() != "tags"
        }

        guard tokens.first?.lowercased() == "market" else {
            return tokens.filter(keep).map { $0.lowercased() }
        }
        return tokens.dropFirst()
            .filter { token in
                let lowered = token.lowercased()
                return lowered != "bid" && lowered != "list" && lowered != "tags"
            }
            .map { $0.lowercased() }
    }

    private static func firstNumber(in tokens: [String]) -> Int? {
        tokens.lazy.compactMap { Int($0) }.first
    }

    private static func parseBidAmount(_ token: String) -> Int? {
        Int(token.replacingOccurrences(of: ",", with: ""))
    }

    private static func itemOnlyCount(for tokens: [String]) -> Int {
        tokens.first == "lbid" ? 2 : 1
    }
}

public enum MarketParser {
    private struct ItemPrefix {
        var showcase: Bool
        var number: Int
        var rest: String
    }

    public static func isOpenTag(_ text: String) -> Bool {
        text == "{market}"
    }

    public static func isCloseTag(_ text: String) -> Bool {
        text == "{/market}"
    }

    public static func listVariant(from lines: [Line]) -> MarketListVariant {
        let header = lines.map(\.text).first { $0.contains("Item Description") } ?? ""
        if header.contains("Buyout") { return .amounts }
        if header.contains("Seller") { return .sellers }
        return .standard
    }

    public static func parseItems(from lines: [Line], variant: MarketListVariant) -> [MarketItem] {
        lines.compactMap { parseItemLine($0, variant: variant) }
    }

    public static func makeDetail(from lines: [Line], itemNumber: Int?) -> MarketDetail {
        var fields: [MarketDetailField] = []
        for line in lines {
            guard line.text.hasPrefix("|"), line.text.hasSuffix("|") else { continue }
            let body = String(line.text.dropFirst().dropLast())
            if let field = parseField(body) {
                fields.append(field)
            } else if let value = parseContinuationValue(body), !fields.isEmpty {
                fields[fields.count - 1].value += " \(value)"
            }
        }
        let title = fields.first { $0.label == "Name" }?.value
            ?? itemNumber.map { "Auction \($0)" }
            ?? "Item Details"
        let resolvedItem = itemNumber ?? fields.first { $0.label == "Market Item Number" }
            .flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }
        return MarketDetail(
            itemNumber: resolvedItem,
            title: title,
            fields: fields,
            rawLines: lines,
            displayLines: makeDetailDisplayLines(from: lines)
        )
    }

    public static func makeHistory(from lines: [Line], itemNumber: Int?) -> MarketBidHistory {
        let title = lines.map(\.text).first { $0.contains("gold based auction") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? itemNumber.map { "Auction \($0) History" }
            ?? "Bid History"
        return MarketBidHistory(
            itemNumber: itemNumber,
            title: title,
            rows: lines.compactMap { parseHistoryRow($0.text) },
            rawLines: lines
        )
    }

    public static func parseAmount(_ raw: String) -> Int? {
        Int(raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func parseItemLine(_ line: Line, variant: MarketListVariant) -> MarketItem? {
        let text = line.text
        guard let parsed = splitItemPrefix(text) else { return nil }
        switch variant {
        case .sellers:
            return parseSellerItem(parsed, source: line)
        case .amounts:
            return parseAmountItem(parsed, source: line)
        case .standard, .filtered:
            return parseStandardItem(parsed, source: line)
        }
    }

    private static func splitItemPrefix(_ text: String) -> ItemPrefix? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let showcase = trimmed.hasPrefix("*")
        let body = showcase ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
        guard body.count > 6 else { return nil }
        let numberText = String(body.prefix(5))
        guard let number = Int(numberText) else { return nil }
        return ItemPrefix(
            showcase: showcase,
            number: number,
            rest: String(body.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func parseStandardItem(_ parsed: ItemPrefix, source: Line) -> MarketItem? {
        let pieces = parsed.rest.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pieces.count >= 6 else { return nil }
        let timeFieldCount = pieces.count >= 2 && pieces[pieces.count - 2].hasSuffix("d") ? 2 : 1
        let timeLeft = pieces.suffix(timeFieldCount).joined(separator: " ")
        let bidIndex = pieces.count - timeFieldCount - 1
        guard bidIndex >= 4 else { return nil }
        let bids = Int(pieces[bidIndex])
        let rawLastBid = pieces[bidIndex - 1]
        let type = pieces[bidIndex - 2]
        let level = Int(pieces[bidIndex - 3])
        let name = pieces[..<(bidIndex - 3)].joined(separator: " ")
        let hasBuyout = type.hasPrefix("*")
        let highBidder = rawLastBid.hasSuffix("*")
        return MarketItem(
            number: parsed.number,
            name: name,
            level: level,
            type: String(type.drop { $0 == "*" }),
            lastBid: parseAmount(rawLastBid.trimmingCharacters(in: CharacterSet(charactersIn: "*"))),
            bidCount: bids,
            timeLeft: timeLeft,
            isShowcase: parsed.showcase,
            hasBuyout: hasBuyout,
            isHighBidder: highBidder,
            nameLine: sliceLine(source, matching: name)
        )
    }

    private static func parseSellerItem(_ parsed: ItemPrefix, source: Line) -> MarketItem? {
        let pieces = parsed.rest.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pieces.count >= 7 else { return nil }
        let lastBidder = pieces.last
        let seller = pieces.dropLast().last
        let lastBid = pieces.dropLast(2).last
        let type = pieces.dropLast(3).last
        let levelText = pieces.dropLast(4).last
        guard let type, let levelText else { return nil }
        let nameCount = pieces.count - 5
        guard nameCount > 0 else { return nil }
        let name = pieces.prefix(nameCount).joined(separator: " ")
        return MarketItem(
            number: parsed.number,
            name: name,
            level: Int(levelText),
            type: type,
            lastBid: lastBid.flatMap(parseAmount),
            seller: seller,
            lastBidder: lastBidder,
            isShowcase: parsed.showcase,
            nameLine: sliceLine(source, matching: name)
        )
    }

    private static func parseAmountItem(_ parsed: ItemPrefix, source: Line) -> MarketItem? {
        let pieces = parsed.rest.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pieces.count >= 7 else { return nil }
        let lastBidder = pieces.last
        let lastBid = pieces.dropLast().last
        let buyout = pieces.dropLast(2).last
        let type = pieces.dropLast(3).last
        let levelText = pieces.dropLast(4).last
        guard let type, let levelText else { return nil }
        let nameCount = pieces.count - 5
        guard nameCount > 0 else { return nil }
        let name = pieces.prefix(nameCount).joined(separator: " ")
        return MarketItem(
            number: parsed.number,
            name: name,
            level: Int(levelText),
            type: type,
            lastBid: lastBid.flatMap(parseAmount),
            lastBidder: lastBidder,
            buyout: buyout.flatMap(parseAmount),
            isShowcase: parsed.showcase,
            hasBuyout: true,
            nameLine: sliceLine(source, matching: name)
        )
    }

    private static func parseField(_ body: String) -> MarketDetailField? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let label = body[..<colon].trimmingCharacters(in: .whitespaces)
        let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !value.isEmpty else { return nil }
        return MarketDetailField(label: label, value: value)
    }

    private static func parseContinuationValue(_ body: String) -> String? {
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let label = body[..<colon].trimmingCharacters(in: .whitespaces)
        let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard label.isEmpty, !value.isEmpty else { return nil }
        return value
    }

    private static func sliceLine(_ line: Line, matching text: String) -> Line? {
        guard let range = line.text.range(of: text) else { return nil }
        let lower = range.lowerBound.utf16Offset(in: line.text)
        let upper = range.upperBound.utf16Offset(in: line.text)
        let keptRange = lower..<upper
        let runs = line.runs.compactMap { shiftedRun($0, keptRange: keptRange, offset: lower) }
        return Line(id: line.id, timestamp: line.timestamp, text: text, runs: runs)
    }

    private static func makeDetailDisplayLines(from lines: [Line]) -> [Line] {
        lines.compactMap { line in
            guard !line.text.hasPrefix("+---") else { return nil }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard trimmed != "History" else { return nil }
            guard !isAuctionMetadataLine(trimmed) else { return nil }
            return strippedFrameLine(line)
        }
    }

    private static func isAuctionMetadataLine(_ text: String) -> Bool {
        let labels = [
            "Market Item Number",
            "Item is being sold by",
            "Auction will end in",
            "Current bid"
        ]
        return labels.contains { text.contains("| \($0)") || text.hasPrefix($0) }
    }

    private static func strippedFrameLine(_ line: Line) -> Line? {
        let raw = line.text
        let framed = raw.hasPrefix("|") && raw.hasSuffix("|")
        let content = framed ? String(raw.dropFirst().dropLast()) : raw
        let leading = content.prefix { $0.isWhitespace }.utf16.count
        let trailing = content.reversed().prefix { $0.isWhitespace }.count
        let startOffset = (framed ? 1 : 0) + leading
        let trimmedLength = max(0, content.utf16.count - leading - trailing)
        guard trimmedLength > 0 else { return nil }

        let stripped = String(content.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
        let keptRange = startOffset..<(startOffset + stripped.utf16.count)
        let runs = line.runs.compactMap { shiftedRun($0, keptRange: keptRange, offset: startOffset) }
        return Line(id: line.id, timestamp: line.timestamp, text: stripped, runs: runs)
    }

    private static func shiftedRun(
        _ run: StyledRun,
        keptRange: Range<Int>,
        offset: Int
    ) -> StyledRun? {
        let lower = max(run.utf16Range.lowerBound, keptRange.lowerBound)
        let upper = min(run.utf16Range.upperBound, keptRange.upperBound)
        guard lower < upper else { return nil }
        return StyledRun(
            utf16Range: (lower - offset)..<(upper - offset),
            style: run.style,
            link: run.link
        )
    }

    private static func parseHistoryRow(_ text: String) -> MarketBidHistoryRow? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.contains("------------"),
              !trimmed.hasPrefix("["),
              !trimmed.hasPrefix("This is a "),
              !trimmed.hasPrefix("Bidder ")
        else { return nil }
        let pieces = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pieces.count >= 5, let amountIndex = pieces.firstIndex(where: { parseAmount($0) != nil }) else {
            return nil
        }
        let bidder = pieces[..<amountIndex].joined(separator: " ")
        let amount = parseAmount(pieces[amountIndex])
        var rest = Array(pieces[(amountIndex + 1)...])
        let isProxy = rest.last == "(proxy)"
        if isProxy { rest.removeLast() }
        return MarketBidHistoryRow(
            bidder: bidder,
            amount: amount,
            time: rest.joined(separator: " "),
            isProxy: isProxy
        )
    }
}
