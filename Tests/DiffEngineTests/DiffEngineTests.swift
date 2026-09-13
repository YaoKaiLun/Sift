import XCTest
import GitKit
@testable import DiffEngine

final class DiffEngineTests: XCTestCase {
    /// 在临时目录里建一个真仓库。DiffEngineTests 无法访问 GitKitTests 里的
    /// FixtureRepo，所以这里放一个最小版本。
    private func makeRepository() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sift-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: url)
        try runGit(["config", "user.email", "t@sift.local"], in: url)
        try runGit(["config", "user.name", "T"], in: url)
        return url
    }

    private func runGit(_ args: [String], in url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func write(_ contents: String, to path: String, in url: URL) throws {
        try write(Data(contents.utf8), to: path, in: url)
    }

    private func write(_ data: Data, to path: String, in url: URL) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func testLoadsTextualDiff() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\nline2\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("line1\nCHANGED\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testCollapsesGeneratedFile() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.load(status: status[0], staged: false, from: repository)

        guard case .collapsed(let reason, let path) = loaded else {
            return XCTFail("期望 collapsed，实际是 \(loaded)")
        }
        XCTAssertEqual(path, "package-lock.json")
        XCTAssertEqual(reason, .pathRule("*-lock.json"))
    }

    func testLoadIgnoringCollapseForcesLoad() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("{}\n", to: "package-lock.json", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("{\"changed\": true}\n", to: "package-lock.json", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let loaded = try await engine.loadIgnoringCollapse(
            status: status[0], staged: false, from: repository)

        guard case .ready = loaded else {
            return XCTFail("强制加载时应返回 ready，实际是 \(loaded)")
        }
    }

    func testUntrackedFileRendersAsAllAdded() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("new line 1\nnew line 2\nnew line 3\n", to: "fresh.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.isUntracked })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.addedLineCount, 3, "未跟踪文件应整个渲染为新增")
        XCTAssertEqual(diff.deletedLineCount, 0)
        XCTAssertEqual(diff.hunks.first?.newStart, 1)
    }

    func testSecondLoadHitsCache() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("line1\n", to: "a.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("changed\n", to: "a.txt", in: url)

        let repository = GitRepository(root: url)
        let cache = DiffCache()
        let engine = DiffEngine(cache: cache)
        let status = try await repository.status()

        _ = try await engine.load(status: status[0], staged: false, from: repository)
        let cached = await cache.value(for: DiffCacheKey(
            worktreePath: url, filePath: "a.txt", staged: false))
        XCTAssertNotNil(cached, "首次加载后应写入缓存")
    }

    /// 超过 500KB 的未跟踪文件必须在读内容之前折叠，不能把整份文件拉进内存。
    func testLargeUntrackedFileCollapsesWithoutReading() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        let huge = url.appendingPathComponent("huge.txt")
        try Data(repeating: UInt8(ascii: "x"), count: 600_000).write(to: huge)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.isUntracked })

        let start = ContinuousClock.now
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)
        let elapsed = ContinuousClock.now - start

        guard case .collapsed(let reason, let path) = loaded else {
            return XCTFail("期望 collapsed，实际是 \(loaded)")
        }
        XCTAssertEqual(path, "huge.txt")
        guard case .tooLarge(let bytes) = reason else {
            return XCTFail("期望 tooLarge，实际是 \(reason)")
        }
        XCTAssertGreaterThan(bytes, 500_000)
        XCTAssertLessThan(elapsed, .milliseconds(50),
                          "折叠不应读取 600KB 文件，耗时 \(elapsed)")
    }

    func testUntrackedPNGLoadsAsImageNotText() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(EnginePNG.red, to: "icon.png", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "icon.png" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("未跟踪 PNG 应为 .image，实际是 \(diff.content)")
        }
        XCTAssertNil(image.old)
        XCTAssertEqual(image.new, .bytes(EnginePNG.red))
        XCTAssertTrue(diff.hunks.isEmpty, "图片不得拆成文本 hunk")
    }

    func testUntrackedNULFileIsBinaryNotText() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(Data((0..<512).map { UInt8($0 % 256) }), to: "blob.bin", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "blob.bin" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.content, .binary)
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testUntrackedTextFileStillRendersAsAllAdded() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write("hello\n", to: "note.txt", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "note.txt" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .textual = diff.content else {
            return XCTFail("普通未跟踪文本应仍是 .textual，实际是 \(diff.content)")
        }
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testModifiedPNGUsesIndexAsOldAndWorktreeAsNew() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(EnginePNG.red, to: "icon.png", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(EnginePNG.blue, to: "icon.png", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let file = try XCTUnwrap(status.first { $0.path == "icon.png" })
        let loaded = try await engine.load(status: file, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("已跟踪 PNG 应为 .image，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.old, .bytes(EnginePNG.red))
        XCTAssertEqual(image.new, .bytes(EnginePNG.blue))
    }

    func testStagedPNGComparesHEADToIndex() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(EnginePNG.red, to: "icon.png", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(EnginePNG.blue, to: "icon.png", in: url)
        try runGit(["add", "icon.png"], in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let file = try XCTUnwrap(status.first { $0.path == "icon.png" })
        let loaded = try await engine.load(status: file, staged: true, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("已暂存 PNG 应为 .image，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.old, .bytes(EnginePNG.red))
        XCTAssertEqual(image.new, .bytes(EnginePNG.blue))
    }

    func testDeletedPNGHasOnlyOldSide() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(EnginePNG.red, to: "icon.png", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("icon.png"))

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let file = try XCTUnwrap(status.first { $0.path == "icon.png" })
        let loaded = try await engine.load(status: file, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("删除 PNG 应为 .image，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.old, .bytes(EnginePNG.red))
        XCTAssertNil(image.new)
    }

    func testStagedRenamePNGReadsOriginalFromHEAD() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write(EnginePNG.red, to: "old.png", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try runGit(["mv", "old.png", "new.png"], in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let file = try XCTUnwrap(status.first { $0.path == "new.png" })
        XCTAssertEqual(file.originalPath, "old.png")
        let loaded = try await engine.load(status: file, staged: true, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("重命名 PNG 应为 .image，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.old, .bytes(EnginePNG.red))
        XCTAssertEqual(image.new, .bytes(EnginePNG.red))
    }

    func testTrackedNonImageBinaryStaysBinary() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("placeholder\n", to: "img.bin", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(Data((0..<512).map { UInt8($0 % 256) }), to: "img.bin", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let file = try XCTUnwrap(status.first { $0.path == "img.bin" })
        let loaded = try await engine.load(status: file, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        XCTAssertEqual(diff.content, .binary)
    }

    func testPNGExtensionNeverBecomesTextual() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(Data((0..<64).map { UInt8($0) }), to: "fake.png", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "fake.png" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        if case .textual = diff.content {
            XCTFail("图片扩展名不得变成 .textual")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("假 PNG 仍走图片通道，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.new, .bytes(Data((0..<64).map { UInt8($0) })))
    }

    func testImageLargerThanLimitIsTooLargeNotLoaded() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)
        try write(EnginePNG.red, to: "icon.png", in: url)

        let repository = GitRepository(root: url, maximumBlobBytes: 10)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "icon.png" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("期望 ready，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("超限 PNG 仍为 .image，实际是 \(diff.content)")
        }
        XCTAssertNil(image.old)
        XCTAssertEqual(image.new, .tooLarge(byteCount: EnginePNG.red.count))
    }

    func testLargeUntrackedPNGDoesNotCollapseAt500KB() async throws {
        let url = try makeRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("seed\n", to: "seed.txt", in: url)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "initial"], in: url)

        var payload = EnginePNG.red
        payload.append(Data(repeating: 0x11, count: 600_000))
        try write(payload, to: "shot.png", in: url)

        let repository = GitRepository(root: url)
        let engine = DiffEngine()
        let status = try await repository.status()
        let untracked = try XCTUnwrap(status.first { $0.path == "shot.png" })
        let loaded = try await engine.load(status: untracked, staged: false, from: repository)

        guard case .ready(let diff) = loaded else {
            return XCTFail("图片不应按 500KB 文本规则折叠，实际是 \(loaded)")
        }
        guard case .image(let image) = diff.content else {
            return XCTFail("期望 .image，实际是 \(diff.content)")
        }
        XCTAssertEqual(image.new, .bytes(payload))
    }
}

private enum EnginePNG {
    static let red = Data([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
        0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0,
        3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68,
        174, 66, 96, 130
    ])
    static let blue = Data([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
        0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 96, 248, 15, 0,
        1, 3, 1, 0, 8, 137, 194, 236, 0, 0, 0, 0, 73, 69, 78, 68,
        174, 66, 96, 130
    ])
}
