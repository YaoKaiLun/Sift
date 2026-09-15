import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum UpdateInstallError: Error, LocalizedError, Sendable {
    case appNotFound
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound:
            return "DMG 里没有找到 Sift.app。"
        case .processFailed(let message):
            return message
        }
    }
}

public enum UpdateInstaller {
    public static func restartScript(pid: Int32, stagedApp: URL, targetApp: URL) -> String {
        let staged = quote(stagedApp.path)
        let target = quote(targetApp.path)
        return """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.2
        done
        ditto \(staged) \(target)
        xattr -cr \(target)
        open \(target)
        rm -f "$0"
        """
    }

    public static func stageDownloadedApp(from dmgURL: URL, cacheDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let dmgFile = cacheDirectory.appendingPathComponent("Sift-update.dmg")
            let (tempURL, _) = try await URLSession.shared.download(from: dmgURL)
            if FileManager.default.fileExists(atPath: dmgFile.path) {
                try FileManager.default.removeItem(at: dmgFile)
            }
            try FileManager.default.moveItem(at: tempURL, to: dmgFile)

            let mountRoot = cacheDirectory.appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            defer {
                _ = try? run("/usr/bin/hdiutil", ["detach", mountRoot.path, "-quiet", "-force"])
                try? FileManager.default.removeItem(at: mountRoot)
            }
            try run("/usr/bin/hdiutil", [
                "attach", "-nobrowse", "-readonly", "-mountpoint", mountRoot.path, dmgFile.path
            ])

            let app = try findSiftApp(in: mountRoot)
            let staged = cacheDirectory.appendingPathComponent("Sift-next.app")
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try run("/usr/bin/ditto", [app.path, staged.path])
            return staged
        }.value
    }

    private static func findSiftApp(in root: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        if let app = contents.first(where: { $0.lastPathComponent == "Sift.app" }) {
            return app
        }
        throw UpdateInstallError.appNotFound
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.processFailed(output.isEmpty ? launchPath : output)
        }
        return output
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
