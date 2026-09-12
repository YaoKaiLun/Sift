public enum TokenKind: Sendable, Equatable {
    case keyword, string, comment, number, type
}

public struct TokenSpan: Sendable, Equatable {
    public let range: Range<Int>
    public let kind: TokenKind

    public init(range: Range<Int>, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}
