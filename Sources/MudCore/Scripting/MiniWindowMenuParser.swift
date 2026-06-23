import Foundation

public enum MiniWindowMenuParser {
    public static func parse(
        pluginID: String,
        windowName: String,
        left: Int,
        top: Int,
        items rawItems: String
    ) -> MiniWindowMenuRequest {
        var body = rawItems
        let returnNumber = body.first == "!"
        if returnNumber { body.removeFirst() }
        var horizontal: MiniWindowMenuRequest.HorizontalAlignment = .left
        var vertical: MiniWindowMenuRequest.VerticalAlignment = .top
        if body.first == "~", body.count > 3 {
            let chars = Array(body.prefix(3))
            horizontal = horizontalAlignment(chars[1])
            vertical = verticalAlignment(chars[2])
            body.removeFirst(3)
        }
        var selectionIndex = 0
        let tokens = body
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        let parsed = parseItems(tokens) {
            selectionIndex += 1
            return selectionIndex
        }
        return MiniWindowMenuRequest(
            pluginID: pluginID,
            windowName: windowName,
            left: left,
            top: top,
            rawItems: rawItems,
            returnNumber: returnNumber,
            horizontalAlignment: horizontal,
            verticalAlignment: vertical,
            items: parsed.items
        )
    }

    private static func parseItems(
        _ tokens: [String],
        nextSelectionIndex: () -> Int
    ) -> (items: [MiniWindowMenuItem], consumed: Int) {
        var items: [MiniWindowMenuItem] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "<" { return (items, index + 1) }
            if token == "-" || token.isEmpty {
                items.append(MiniWindowMenuItem(title: ""))
                index += 1
                continue
            }
            if token.hasPrefix(">") {
                let child = parseItems(
                    Array(tokens.dropFirst(index + 1)),
                    nextSelectionIndex: nextSelectionIndex
                )
                items.append(MiniWindowMenuItem(title: String(token.dropFirst()), children: child.items))
                index += 1 + child.consumed
                continue
            }
            items.append(parseLeaf(token, nextSelectionIndex: nextSelectionIndex))
            index += 1
        }
        return (items, index)
    }

    private static func parseLeaf(
        _ token: String,
        nextSelectionIndex: () -> Int
    ) -> MiniWindowMenuItem {
        var value = token
        var checked = false
        var disabled = false
        while let first = value.first, first == "+" || first == "^" {
            checked = checked || first == "+"
            disabled = disabled || first == "^"
            value.removeFirst()
        }
        return MiniWindowMenuItem(
            title: value,
            selectionIndex: disabled ? nil : nextSelectionIndex(),
            checked: checked,
            disabled: disabled
        )
    }

    private static func horizontalAlignment(_ value: Character) -> MiniWindowMenuRequest.HorizontalAlignment {
        switch value.lowercased() {
        case "c": .center
        case "r": .right
        default: .left
        }
    }

    private static func verticalAlignment(_ value: Character) -> MiniWindowMenuRequest.VerticalAlignment {
        switch value.lowercased() {
        case "c": .center
        case "b": .bottom
        default: .top
        }
    }
}
