import AppKit
import GitKit
import DiffEngine

public struct DiffHunkHeader: Sendable, Equatable {
    public let id: String
    public let range: NSRange

    public init(id: String, range: NSRange) {
        self.id = id
        self.range = range
    }
}

public enum DiffLayout: Sendable {
    case unified
    case split
}

extension NSAttributedString.Key {
    public static let siftRole = NSAttributedString.Key("siftRole")
}

public struct DiffFileHeader: Sendable, Equatable {
    public let id: String
    public let range: NSRange
    public let isPlaceholder: Bool
    public let isCollapsed: Bool

    public init(id: String, range: NSRange, isPlaceholder: Bool, isCollapsed: Bool) {
        self.id = id
        self.range = range
        self.isPlaceholder = isPlaceholder
        self.isCollapsed = isCollapsed
    }
}

public struct DiffDocument: @unchecked Sendable {
    public let text: NSAttributedString
    public let splitRight: NSAttributedString?
    public let hunkHeaders: [DiffHunkHeader]
    public let fileHeaders: [DiffFileHeader]

    /// 分栏左栏；统一视图下就是全文。与 `text` 同一份文档。
    public var splitLeft: NSAttributedString { text }

    public init(text: NSAttributedString,
                splitRight: NSAttributedString? = nil,
                hunkHeaders: [DiffHunkHeader] = [],
                fileHeaders: [DiffFileHeader] = []) {
        self.text = text
        self.splitRight = splitRight
        self.hunkHeaders = hunkHeaders
        self.fileHeaders = fileHeaders
    }
}

/// 把 FileDiff 转成一篇带 hunk 头区间的 DiffDocument，交给 NSTextView 显示。
///
/// 纯函数，没有 UI 依赖，因此可以完整测试，也可以放到主线程之外去跑。
///
/// 行号写进文本本身并标 `.siftRole = gutter`。复制走 `copyableString`，丢掉行号列。
public enum DiffDocumentBuilder {
    private static let gutterWidth = 4

    /// 选区按行处理：丢掉 gutter，保留 header/code；分栏对齐空行不进结果。
    public static func copyableString(from text: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= text.length else { return "" }

        let ns = text.string as NSString
        var result = ""
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let slice = NSIntersectionRange(lineRange, range)
            if slice.length == 0 { break }

            var keepsLine = false
            var lineText = ""
            text.enumerateAttributes(in: slice) { attrs, run, _ in
                let role = attrs[.siftRole] as? String
                if role == "gutter" { return }
                if role == "code" || role == "header" { keepsLine = true }
                lineText += ns.substring(with: run)
            }
            if keepsLine {
                result += lineText
            }
            location = NSMaxRange(slice)
        }
        return result
    }

    /// 把选区扩成整行，再各向外扩 `extraLines` 行，供解释请求带上下文。
    public static func surroundingRange(of selection: NSRange,
                                        in string: String,
                                        extraLines: Int = 8) -> NSRange {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = NSIntersectionRange(selection, full)
        guard clamped.location != NSNotFound else { return NSRange(location: 0, length: 0) }

        var start: Int
        var end: Int
        if clamped.length == 0 {
            let line = ns.lineRange(for: NSRange(location: min(clamped.location, ns.length - 1), length: 0))
            start = line.location
            end = NSMaxRange(line)
        } else {
            start = ns.lineRange(for: NSRange(location: clamped.location, length: 0)).location
            let last = max(clamped.location, NSMaxRange(clamped) - 1)
            end = NSMaxRange(ns.lineRange(for: NSRange(location: last, length: 0)))
        }

        for _ in 0..<extraLines {
            guard start > 0 else { break }
            start = ns.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        for _ in 0..<extraLines {
            guard end < ns.length else { break }
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            if next.length == 0 { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    public static func build(_ diff: FileDiff,
                             layout: DiffLayout = .unified,
                             hunkIDPrefix: String = "") -> DiffDocument {
        guard case .textual(let hunks) = diff.content, !hunks.isEmpty else {
            return DiffDocument(text: NSAttributedString(), hunkHeaders: [])
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.codeLineHeight
        paragraph.maximumLineHeight = Theme.codeLineHeight
        // 代码不换行；横向滚动比自动折行更容易读懂 diff。
        paragraph.lineBreakMode = .byClipping
        // `Theme.codeNSFont` 是 `@MainActor`（Swift 6 / Task 12）。构建器要能在测试线程跑，
        // 所以这里直接取同样的等宽系统字体，不经过 Theme。
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let colors = DiffColors()

        switch layout {
        case .unified:
            return buildUnified(hunks: hunks, paragraph: paragraph, font: font, colors: colors,
                                hunkIDPrefix: hunkIDPrefix)
        case .split:
            return buildSplit(hunks: hunks, paragraph: paragraph, font: font, colors: colors,
                              hunkIDPrefix: hunkIDPrefix)
        }
    }

    /// 连续滚动：每个文件先占位头，已展开的再接上真正 diff。
    public static func buildContinuous(
        sections: [(ContinuousDiffEntry, LoadedDiff?)],
        layout: DiffLayout = .unified
    ) -> DiffDocument {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.codeLineHeight
        paragraph.maximumLineHeight = Theme.codeLineHeight
        paragraph.lineBreakMode = .byClipping
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let colors = DiffColors()

        let left = NSMutableAttributedString()
        let right = layout == .split ? NSMutableAttributedString() : nil
        var hunkHeaders: [DiffHunkHeader] = []
        var fileHeaders: [DiffFileHeader] = []

        for (index, section) in sections.enumerated() {
            if index > 0 {
                left.append(separatorLine(paragraph: paragraph, font: font))
                right?.append(separatorLine(paragraph: paragraph, font: font))
            }
            appendContinuousSection(
                section.0, loaded: section.1, layout: layout,
                left: left, right: right,
                hunkHeaders: &hunkHeaders, fileHeaders: &fileHeaders,
                paragraph: paragraph, font: font, colors: colors)
        }

        return DiffDocument(
            text: left,
            splitRight: right,
            hunkHeaders: hunkHeaders,
            fileHeaders: fileHeaders)
    }

    public static func buildContinuousOffMainActor(
        sections: [(ContinuousDiffEntry, LoadedDiff?)],
        layout: DiffLayout = .unified
    ) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            buildContinuous(sections: sections, layout: layout)
        }.value
    }

    /// 把大文档的构建挪出主线程。DiffDocument 以 @unchecked Sendable 跨隔离域交回。
    public static func buildOffMainActor(_ diff: FileDiff,
                                         layout: DiffLayout = .unified) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            build(diff, layout: layout)
        }.value
    }

    private static func buildUnified(hunks: [Hunk],
                                     paragraph: NSParagraphStyle,
                                     font: NSFont,
                                     colors: DiffColors,
                                     hunkIDPrefix: String) -> DiffDocument {
        let document = NSMutableAttributedString()
        var headers: [DiffHunkHeader] = []
        headers.reserveCapacity(hunks.count)

        for (index, hunk) in hunks.enumerated() {
            if index > 0 { document.append(separatorLine(paragraph: paragraph, font: font)) }
            let location = document.length
            let header = headerLine(for: hunk, paragraph: paragraph, font: font)
            document.append(header)
            headers.append(DiffHunkHeader(
                id: hunkIDPrefix + hunk.id,
                range: NSRange(location: location, length: header.length)))
            for line in hunk.lines {
                document.append(bodyLine(line, gutter: .unified,
                                         paragraph: paragraph, font: font, colors: colors))
            }
        }
        return DiffDocument(text: document, splitRight: nil, hunkHeaders: headers)
    }

    private static func buildSplit(hunks: [Hunk],
                                   paragraph: NSParagraphStyle,
                                   font: NSFont,
                                   colors: DiffColors,
                                   hunkIDPrefix: String) -> DiffDocument {
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        var headers: [DiffHunkHeader] = []
        headers.reserveCapacity(hunks.count)

        for (index, hunk) in hunks.enumerated() {
            if index > 0 {
                left.append(separatorLine(paragraph: paragraph, font: font))
                right.append(separatorLine(paragraph: paragraph, font: font))
            }
            let location = left.length
            let header = headerLine(for: hunk, paragraph: paragraph, font: font)
            left.append(header)
            right.append(header)
            headers.append(DiffHunkHeader(
                id: hunkIDPrefix + hunk.id,
                range: NSRange(location: location, length: header.length)))
            for line in hunk.lines {
                appendSplitLine(line, left: left, right: right,
                                paragraph: paragraph, font: font, colors: colors)
            }
        }
        return DiffDocument(text: left, splitRight: right, hunkHeaders: headers)
    }

    private static func appendContinuousSection(
        _ entry: ContinuousDiffEntry,
        loaded: LoadedDiff?,
        layout: DiffLayout,
        left: NSMutableAttributedString,
        right: NSMutableAttributedString?,
        hunkHeaders: inout [DiffHunkHeader],
        fileHeaders: inout [DiffFileHeader],
        paragraph: NSParagraphStyle,
        font: NSFont,
        colors: DiffColors
    ) {
        let header = fileHeaderLine(title: entry.headerTitle, paragraph: paragraph, font: font)
        let headerRange = NSRange(location: left.length, length: header.length)
        left.append(header)
        right?.append(header)

        switch loaded {
        case .none:
            fileHeaders.append(DiffFileHeader(
                id: entry.id, range: headerRange, isPlaceholder: true, isCollapsed: false))
        case .collapsed(let reason, _):
            fileHeaders.append(DiffFileHeader(
                id: entry.id, range: headerRange, isPlaceholder: false, isCollapsed: true))
            let note = statusNote(
                "这是生成文件或体积过大的文件（\(reason.explanation)），已默认折叠。\n",
                paragraph: paragraph, font: font)
            left.append(note)
            right?.append(note)
        case .ready(let diff):
            fileHeaders.append(DiffFileHeader(
                id: entry.id, range: headerRange, isPlaceholder: false, isCollapsed: false))
            appendReadyDiff(diff, layout: layout, hunkIDPrefix: entry.id + ":",
                            left: left, right: right, hunkHeaders: &hunkHeaders,
                            paragraph: paragraph, font: font, colors: colors)
        }
    }

    private static func appendReadyDiff(
        _ diff: FileDiff,
        layout: DiffLayout,
        hunkIDPrefix: String,
        left: NSMutableAttributedString,
        right: NSMutableAttributedString?,
        hunkHeaders: inout [DiffHunkHeader],
        paragraph: NSParagraphStyle,
        font: NSFont,
        colors: DiffColors
    ) {
        switch diff.content {
        case .textual(let hunks) where !hunks.isEmpty:
            let part = build(diff, layout: layout, hunkIDPrefix: hunkIDPrefix)
            let offset = left.length
            left.append(part.text)
            if let rightText = part.splitRight {
                right?.append(rightText)
            } else if let right {
                right.append(part.text)
            }
            hunkHeaders.append(contentsOf: part.hunkHeaders.map {
                DiffHunkHeader(
                    id: $0.id,
                    range: NSRange(location: $0.range.location + offset, length: $0.range.length))
            })
        case .binary:
            let note = statusNote("二进制文件\n", paragraph: paragraph, font: font)
            left.append(note)
            right?.append(note)
        case .modeChangeOnly(let oldMode, let newMode):
            let note = statusNote("只有文件权限变化  \(oldMode) → \(newMode)\n",
                                  paragraph: paragraph, font: font)
            left.append(note)
            right?.append(note)
        default:
            let note = statusNote("此文件没有文本差异\n", paragraph: paragraph, font: font)
            left.append(note)
            right?.append(note)
        }
    }

    private static func fileHeaderLine(title: String,
                                       paragraph: NSParagraphStyle,
                                       font: NSFont) -> NSAttributedString {
        NSAttributedString(string: title + "\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.textColor.withAlphaComponent(0.08),
            .paragraphStyle: paragraph,
            .siftRole: "header",
        ])
    }

    private static func statusNote(_ text: String,
                                   paragraph: NSParagraphStyle,
                                   font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
            .siftRole: "header",
        ])
    }

    private static func appendSplitLine(_ line: DiffLine,
                                        left: NSMutableAttributedString,
                                        right: NSMutableAttributedString,
                                        paragraph: NSParagraphStyle,
                                        font: NSFont,
                                        colors: DiffColors) {
        switch line.kind {
        case .context:
            left.append(bodyLine(line, gutter: .oldOnly,
                                 paragraph: paragraph, font: font, colors: colors))
            right.append(bodyLine(line, gutter: .newOnly,
                                  paragraph: paragraph, font: font, colors: colors))
        case .deletion:
            left.append(bodyLine(line, gutter: .oldOnly,
                                 paragraph: paragraph, font: font, colors: colors))
            right.append(alignmentSpacer(paragraph: paragraph, font: font))
        case .addition:
            left.append(alignmentSpacer(paragraph: paragraph, font: font))
            right.append(bodyLine(line, gutter: .newOnly,
                                  paragraph: paragraph, font: font, colors: colors))
        case .noNewlineMarker:
            let marker = bodyLine(line, gutter: .unified,
                                  paragraph: paragraph, font: font, colors: colors)
            left.append(marker)
            right.append(marker)
        }
    }

    private static func headerLine(for hunk: Hunk,
                                   paragraph: NSParagraphStyle,
                                   font: NSFont) -> NSAttributedString {
        let heading = hunk.sectionHeading.isEmpty ? "" : "  \(hunk.sectionHeading)"
        let text = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(heading)\n"
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            // quaternarySystemFill 在深色下几乎看不见，hunk 分界必须能一眼看出来。
            .backgroundColor: NSColor.textColor.withAlphaComponent(0.08),
            .paragraphStyle: paragraph,
            .siftRole: "header",
        ])
    }

    private enum GutterStyle {
        case unified
        case oldOnly
        case newOnly
    }

    private static func bodyLine(_ line: DiffLine,
                                 gutter style: GutterStyle,
                                 paragraph: NSParagraphStyle,
                                 font: NSFont,
                                 colors: DiffColors) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: "\\ 文件末尾没有换行符\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
                .siftRole: "code",
            ])
        }

        let gutter: String
        switch style {
        case .unified:
            let oldNumber = line.oldLineNumber.map(String.init) ?? ""
            let newNumber = line.newLineNumber.map(String.init) ?? ""
            gutter = pad(oldNumber) + " " + pad(newNumber) + " "
        case .oldOnly:
            gutter = pad(line.oldLineNumber.map(String.init) ?? "") + " "
        case .newOnly:
            gutter = pad(line.newLineNumber.map(String.init) ?? "") + " "
        }

        let marker: String
        switch line.kind {
        case .addition: marker = "+"
        case .deletion: marker = "-"
        default: marker = " "
        }

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: gutter, attributes: [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .backgroundColor: colors.gutter(for: line.kind),
            .paragraphStyle: paragraph,
            .siftRole: "gutter",
        ]))
        result.append(NSAttributedString(string: "\(marker)\(line.text)\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: colors.body(for: line.kind),
            .paragraphStyle: paragraph,
            .siftRole: "code",
        ]))
        return result
    }

    /// 分栏缺行：只含换行、无 gutter、不标 code，复制时丢掉。
    private static func alignmentSpacer(paragraph: NSParagraphStyle, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
    }

    private static func separatorLine(paragraph: NSParagraphStyle, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
    }

    private static func pad(_ text: String) -> String {
        text.count >= gutterWidth
            ? text
            : String(repeating: " ", count: gutterWidth - text.count) + text
    }

    private struct DiffColors {
        let addition = NSColor(named: "DiffAddition", bundle: .module) ?? .clear
        let deletion = NSColor(named: "DiffDeletion", bundle: .module) ?? .clear
        let additionGutter = NSColor(named: "DiffAdditionGutter", bundle: .module) ?? .clear
        let deletionGutter = NSColor(named: "DiffDeletionGutter", bundle: .module) ?? .clear

        func body(for kind: DiffLineKind) -> NSColor {
            switch kind {
            case .addition: addition
            case .deletion: deletion
            default: .clear
            }
        }

        func gutter(for kind: DiffLineKind) -> NSColor {
            switch kind {
            case .addition: additionGutter
            case .deletion: deletionGutter
            default: .clear
            }
        }
    }
}
