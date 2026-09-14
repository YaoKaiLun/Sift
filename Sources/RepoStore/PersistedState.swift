import Foundation
import DiffEngine

public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct PersistedState: Codable, Sendable, Equatable {
    /// security-scoped 书签。沙盒环境下重启后仍能访问用户选过的目录，
    /// 存路径字符串是不够的。
    public var repositoryBookmarks: [Data]
    public var selectedWorktreePath: String?
    public var usesTreeView: Bool
    public var usesSplitDiff: Bool
    public var appearance: AppearancePreference
    /// OpenAI 兼容接口的根路径。缺省空，不预填任何服务商。
    public var explainBaseURL: String
    public var explainModel: String
    public var sidebarWidth: Double
    public var fileListWidth: Double
    public var usesContinuousDiff: Bool
    public var showsBlame: Bool
    public var hidesFilteredFiles: Bool
    public var fileFilterPatterns: [String]

    public init(repositoryBookmarks: [Data] = [],
                selectedWorktreePath: String? = nil,
                usesTreeView: Bool = false,
                usesSplitDiff: Bool = false,
                appearance: AppearancePreference = .system,
                explainBaseURL: String = "",
                explainModel: String = "",
                sidebarWidth: Double = 220,
                fileListWidth: Double = 300,
                usesContinuousDiff: Bool = false,
                showsBlame: Bool = false,
                hidesFilteredFiles: Bool = false,
                fileFilterPatterns: [String] = FileFilter.defaultPatterns) {
        self.repositoryBookmarks = repositoryBookmarks
        self.selectedWorktreePath = selectedWorktreePath
        self.usesTreeView = usesTreeView
        self.usesSplitDiff = usesSplitDiff
        self.appearance = appearance
        self.explainBaseURL = explainBaseURL
        self.explainModel = explainModel
        self.sidebarWidth = sidebarWidth
        self.fileListWidth = fileListWidth
        self.usesContinuousDiff = usesContinuousDiff
        self.showsBlame = showsBlame
        self.hidesFilteredFiles = hidesFilteredFiles
        self.fileFilterPatterns = fileFilterPatterns
    }

    public static let defaultFileFilterPatterns: [String] = FileFilter.defaultPatterns

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositoryBookmarks = try container.decodeIfPresent([Data].self, forKey: .repositoryBookmarks) ?? []
        selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
        usesTreeView = try container.decodeIfPresent(Bool.self, forKey: .usesTreeView) ?? false
        usesSplitDiff = try container.decodeIfPresent(Bool.self, forKey: .usesSplitDiff) ?? false
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        explainBaseURL = try container.decodeIfPresent(String.self, forKey: .explainBaseURL) ?? ""
        explainModel = try container.decodeIfPresent(String.self, forKey: .explainModel) ?? ""
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 220
        fileListWidth = try container.decodeIfPresent(Double.self, forKey: .fileListWidth) ?? 300
        usesContinuousDiff = try container.decodeIfPresent(Bool.self, forKey: .usesContinuousDiff) ?? false
        showsBlame = try container.decodeIfPresent(Bool.self, forKey: .showsBlame) ?? false
        hidesFilteredFiles = try container.decodeIfPresent(Bool.self, forKey: .hidesFilteredFiles) ?? false
        fileFilterPatterns = try container.decodeIfPresent([String].self, forKey: .fileFilterPatterns)
            ?? FileFilter.defaultPatterns
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
