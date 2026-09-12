import XCTest
@testable import DiffEngine

final class GeneratedFileDetectorTests: XCTestCase {
    private let detector = GeneratedFileDetector()

    func testLockFilesAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "pnpm-lock.yaml", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "package-lock.json", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "Cargo.lock", lineCount: 10, byteCount: 100))
    }

    func testBuildOutputDirectoriesAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "dist/index.js", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "apps/web/build/main.css", lineCount: 10, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "node_modules/foo/index.js", lineCount: 10, byteCount: 100))
    }

    func testMinifiedAndSourceMapsAreGenerated() {
        XCTAssertNotNil(detector.reason(forPath: "assets/app.min.js", lineCount: 5, byteCount: 100))
        XCTAssertNotNil(detector.reason(forPath: "assets/app.js.map", lineCount: 5, byteCount: 100))
    }

    func testOrdinarySourceIsNotGenerated() {
        XCTAssertNil(detector.reason(forPath: "src/main.swift", lineCount: 200, byteCount: 5_000))
        XCTAssertNil(detector.reason(forPath: "apps/web/src/App.tsx", lineCount: 200, byteCount: 5_000))
    }

    /// 目录名恰好包含规则关键字，但不是那个目录，不应误判。
    func testDirectoryRuleMatchesPathComponentNotSubstring() {
        XCTAssertNil(detector.reason(forPath: "src/distribution/list.ts", lineCount: 10, byteCount: 100),
                     "distribution 不是 dist 目录")
        XCTAssertNil(detector.reason(forPath: "src/rebuild/index.ts", lineCount: 10, byteCount: 100),
                     "rebuild 不是 build 目录")
    }

    func testTooManyLines() {
        let reason = detector.reason(forPath: "src/huge.ts", lineCount: 5_000, byteCount: 10_000)
        guard case .tooManyLines(let count)? = reason else {
            return XCTFail("期望 tooManyLines，实际是 \(String(describing: reason))")
        }
        XCTAssertEqual(count, 5_000)
    }

    func testTooManyBytes() {
        let reason = detector.reason(forPath: "src/huge.ts", lineCount: 100, byteCount: 900_000)
        guard case .tooLarge? = reason else {
            return XCTFail("期望 tooLarge，实际是 \(String(describing: reason))")
        }
    }

    func testUnknownSizeIsNotGenerated() {
        XCTAssertNil(detector.reason(forPath: "src/main.swift", lineCount: nil, byteCount: nil))
    }

    func testCustomRulesReplaceDefaults() {
        let custom = GeneratedFileDetector(pathRules: ["*.generated.ts"])
        XCTAssertNotNil(custom.reason(forPath: "src/api.generated.ts", lineCount: 10, byteCount: 100))
        XCTAssertNil(custom.reason(forPath: "pnpm-lock.yaml", lineCount: 10, byteCount: 100),
                     "自定义规则应替换默认规则而非叠加")
    }
}
