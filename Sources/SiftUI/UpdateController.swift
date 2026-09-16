import AppKit
import Foundation
import Observation
import UpdateKit
import SiftLocalization

@MainActor
@Observable
public final class UpdateController {
    public enum State: Equatable {
        case idle
        case checking
        case available(AvailableUpdate)
        case downloading
        case ready(version: Version, staged: URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public var userMessage: String?

    private let current: Version
    private let fetching: any ReleaseFetching
    private var downloadTask: Task<Void, Never>?

    public init(current: Version? = nil, fetching: (any ReleaseFetching)? = nil) {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.current = current
            ?? bundleVersion.flatMap(Version.init)
            ?? Version("0")!
        self.fetching = fetching ?? GitHubReleaseFetcher()
    }

    public func check(automatic: Bool) async {
        if automatic {
            #if DEBUG
            return
            #endif
            if Bundle.main.bundlePath.contains("DerivedData") { return }
        }
        state = .checking
        do {
            let result = try await UpdateChecker.check(current: current, fetching: fetching)
            switch result {
            case .upToDate:
                state = .idle
                if !automatic {
                    userMessage = L10n.upToDate(current.description)
                }
            case .available(let update):
                state = .available(update)
            case .noInstallableAsset:
                state = .idle
                if !automatic {
                    userMessage = L10n.noInstallableDMG
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if !automatic {
                userMessage = L10n.cannotCheckUpdates
            } else {
                state = .idle
            }
        }
    }

    public func download() {
        guard case .available(let update) = state else { return }
        state = .downloading
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Sift/updates", isDirectory: true)
                let staged = try await UpdateInstaller.stageDownloadedApp(
                    from: update.dmgURL, cacheDirectory: cache)
                guard !Task.isCancelled else { return }
                self.state = .ready(version: update.version, staged: staged)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
                self.userMessage = L10n.cannotInstallUpdate
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = state {
            state = .idle
        }
    }

    public func restart() {
        guard case .ready(_, let staged) = state else { return }
        let target = Bundle.main.bundleURL
        let script = UpdateInstaller.restartScript(
            pid: ProcessInfo.processInfo.processIdentifier,
            stagedApp: staged,
            targetApp: target)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sift-update.sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [url.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            userMessage = L10n.cannotInstallUpdate
        }
    }
}
