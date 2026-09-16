import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AvailableUpdate: Sendable, Equatable {
    public var version: Version
    public var dmgURL: URL

    public init(version: Version, dmgURL: URL) {
        self.version = version
        self.dmgURL = dmgURL
    }
}

public protocol ReleaseFetching: Sendable {
    func latestReleaseData() async throws -> Data
}

public struct GitHubReleaseFetcher: ReleaseFetching {
    private let session: URLSession
    private let url: URL
    private let pageURL: URL

    public init(session: URLSession = .shared,
                url: URL = URL(string: "https://api.github.com/repos/YaoKaiLun/Sift/releases/latest")!,
                pageURL: URL = URL(string: "https://github.com/YaoKaiLun/Sift/releases/latest")!) {
        self.session = session
        self.url = url
        self.pageURL = pageURL
    }

    public func latestReleaseData() async throws -> Data {
        do {
            return try await fetchAPI()
        } catch {
            return try await fetchReleasePage()
        }
    }

    private func fetchAPI() async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Sift", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// API 限流或被拦截时，跟网页 latest 的 302 拿 tag，再按约定拼 DMG 地址。
    private func fetchReleasePage() async throws -> Data {
        var request = URLRequest(url: pageURL)
        request.setValue("Sift", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let finalURL = response.url,
              let tag = GitHubLatestRelease.tagName(fromReleasePage: finalURL) else {
            throw URLError(.badServerResponse)
        }
        return GitHubLatestRelease.synthesizedData(tagName: tag)
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(AvailableUpdate)
    case noInstallableAsset
}

public enum UpdateChecker {
    public static func check(current: Version, fetching: any ReleaseFetching) async throws -> UpdateCheckResult {
        let release = try GitHubLatestRelease.decode(try await fetching.latestReleaseData())
        guard let version = release.version, let url = release.dmgURL else {
            return .noInstallableAsset
        }
        if version <= current {
            return .upToDate
        }
        return .available(AvailableUpdate(version: version, dmgURL: url))
    }
}
