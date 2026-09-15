import Foundation

public struct GitHubLatestRelease: Sendable, Equatable, Decodable {
    public var tagName: String
    public var assets: [Asset]

    public var version: Version? { Version(tagName) }

    public var dmgURL: URL? {
        assets.first { asset in
            asset.name.range(of: #"^Sift-.*\.dmg$"#, options: .regularExpression) != nil
        }.flatMap { URL(string: $0.browserDownloadURL) }
    }

    public struct Asset: Sendable, Equatable, Decodable {
        public var name: String
        public var browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    public static func decode(_ data: Data) throws -> GitHubLatestRelease {
        try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
    }
}
