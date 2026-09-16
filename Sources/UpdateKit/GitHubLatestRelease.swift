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

    public static func tagName(fromReleasePage url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "tag"), parts.indices.contains(index + 1) else {
            return nil
        }
        let tag = parts[index + 1]
        return tag.isEmpty ? nil : tag
    }

    public static func synthesizedData(tagName: String) -> Data {
        let version = Version(tagName)?.description ?? tagName
        let name = "Sift-\(version).dmg"
        let download = "https://github.com/YaoKaiLun/Sift/releases/download/\(tagName)/\(name)"
        let json = """
        {"tag_name":"\(tagName)","assets":[{"name":"\(name)","browser_download_url":"\(download)"}]}
        """
        return Data(json.utf8)
    }
}
