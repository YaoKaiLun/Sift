import AppKit
import GitKit

/// 把 FileDiff 转成一个可直接交给 NSTextView 的 NSAttributedString。
///
/// 纯函数，没有 UI 依赖，因此可以完整测试，也可以放到主线程之外去跑。
///
/// 行号写进文本本身（而不是画在单独的视图里），这样选中和复制会自然工作，
/// 也不需要维护第二个视图跟主文本滚动同步。代价是复制出来会带行号，
/// 计划二会加一个"复制时剔除行号"的处理。
public enum DiffDocumentBuilder {
    private static let gutterWidth = 4

    public static func build(_ diff: FileDiff) -> NSAttributedString {
        guard case .textual(let hunks) = diff.content, !hunks.isEmpty else {
            return NSAttributedString()
        }

        let document = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.codeLineHeight
        paragraph.maximumLineHeight = Theme.codeLineHeight
        // 代码不换行；横向滚动比自动折行更容易读懂 diff。
        paragraph.lineBreakMode = .byClipping
        // `Theme.codeNSFont` 是 `@MainActor`（Swift 6 / Task 12）。构建器要能在测试线程跑，
        // 所以这里直接取同样的等宽系统字体，不经过 Theme。
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let colors = DiffColors()

        for (index, hunk) in hunks.enumerated() {
            if index > 0 { document.append(NSAttributedString(string: "\n")) }
            document.append(headerLine(for: hunk, paragraph: paragraph, font: font))
            for line in hunk.lines {
                document.append(bodyLine(line, paragraph: paragraph, font: font, colors: colors))
            }
        }
        return document
    }

    private static func headerLine(for hunk: Hunk,
                                   paragraph: NSParagraphStyle,
                                   font: NSFont) -> NSAttributedString {
        let heading = hunk.sectionHeading.isEmpty ? "" : "  \(hunk.sectionHeading)"
        let text = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(heading)\n"
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.quaternarySystemFill,
            .paragraphStyle: paragraph,
        ])
    }

    private static func bodyLine(_ line: DiffLine,
                                 paragraph: NSParagraphStyle,
                                 font: NSFont,
                                 colors: DiffColors) -> NSAttributedString {
        if line.kind == .noNewlineMarker {
            return NSAttributedString(string: "\\ 文件末尾没有换行符\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        }

        let oldNumber = line.oldLineNumber.map(String.init) ?? ""
        let newNumber = line.newLineNumber.map(String.init) ?? ""
        let gutter = pad(oldNumber) + " " + pad(newNumber) + " "

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
        ]))
        result.append(NSAttributedString(string: "\(marker)\(line.text)\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: colors.body(for: line.kind),
            .paragraphStyle: paragraph,
        ]))
        return result
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
