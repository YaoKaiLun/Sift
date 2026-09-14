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

    public init(session: URLSession = .shared,
                url: URL = URL(string: "https://api.github.com/repos/YaoKaiLun/Sift/releases/latest")!) {
        self.session = session
        self.url = url
    }

    public func latestReleaseData() async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Sift", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
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
