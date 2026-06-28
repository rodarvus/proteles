import Foundation

extension LuaRuntime {
    static func bridgeString(_ value: LuaValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            let isIntegral = number.isFinite &&
                number >= Double(Int64.min) && number <= Double(Int64.max) &&
                number.rounded(.towardZero) == number
            if isIntegral {
                return String(Int64(number))
            }
            return String(number)
        case .boolean(let boolean):
            return boolean ? "true" : "false"
        case .bytes(let data):
            return String(decoding: data, as: UTF8.self)
        case .nil, .functionRef:
            return ""
        }
    }
}
