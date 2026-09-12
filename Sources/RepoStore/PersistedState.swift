import Foundation

public struct PersistedState: Codable, Sendable, Equatable {
    /// security-scoped 书签。沙盒环境下重启后仍能访问用户选过的目录，
    /// 存路径字符串是不够的。
    public var repositoryBookmarks: [Data]
    public var selectedWorktreePath: String?
    public var usesTreeView: Bool

    public init(repositoryBookmarks: [Data] = [],
                selectedWorktreePath: String? = nil,
                usesTreeView: Bool = false) {
        self.repositoryBookmarks = repositoryBookmarks
        self.selectedWorktreePath = selectedWorktreePath
        self.usesTreeView = usesTreeView
    }
}

public struct PersistedStateStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = PersistedStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sift/state.json")
    }

    /// 读失败一律返回空状态。用户的偏好设置丢了是小事，启动不了是大事。
    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
