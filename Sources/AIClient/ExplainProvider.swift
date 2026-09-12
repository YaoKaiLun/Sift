import Foundation

public enum ExplainError: Error, Sendable, Equatable {
    case notConfigured
}

public struct ExplainTurn: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ExplainRequest: Sendable {
    public let path: String
    public let selectedText: String
    public let surroundingText: String
    public let fileDiff: String
    public let history: [ExplainTurn]

    public init(
        path: String,
        selectedText: String,
        surroundingText: String,
        fileDiff: String,
        history: [ExplainTurn]
    ) {
        self.path = path
        self.selectedText = selectedText
        self.surroundingText = surroundingText
        self.fileDiff = fileDiff
        self.history = history
    }
}

public protocol ExplainProvider: Sendable {
    func stream(_ request: ExplainRequest) -> AsyncThrowingStream<String, Error>
}
