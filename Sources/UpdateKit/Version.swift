import Foundation

public struct Version: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part) else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return (0..<count).allSatisfy { lhs[$0] == rhs[$0] }
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] }
        }
        return false
    }

    private subscript(_ index: Int) -> Int {
        index < components.count ? components[index] : 0
    }
}
