import Foundation

/// 在临时目录中创建一次性 git 仓库，供解析器测试使用。
/// 每个实例拥有独立目录，析构时自动清理。
final class FixtureRepo {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-b", "main")
        try git("config", "user.email", "test@sift.local")
        try git("config", "user.name", "Sift Test")
        try git("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        try runGit(args)
    }

    @discardableResult
    func runGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError.gitFailed(args.joined(separator: " "), output)
        }
        return output
    }

    func write(_ contents: String, to path: String) throws {
        try write(Data(contents.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-m", message)
    }

    enum FixtureError: Error {
        case gitFailed(String, String)
    }
}
