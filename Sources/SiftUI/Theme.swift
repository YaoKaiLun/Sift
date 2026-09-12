import AppKit
import SwiftUI

/// 视觉规范的唯一出口。颜色一律走系统语义色，
/// 只有 diff 的增删色是自定义的——这两个必须为浅色与深色分别调校。
public enum Theme {
    public static let interfaceFont = Font.system(size: 13)
    public static let codeFont = Font.system(size: 12, design: .monospaced)

    /// NSTextView 需要 NSFont 而不是 SwiftUI 的 Font。
    @MainActor
    public static let codeNSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    public static let additionBackground = Color("DiffAddition", bundle: .module)
    public static let deletionBackground = Color("DiffDeletion", bundle: .module)
    public static let additionGutter = Color("DiffAdditionGutter", bundle: .module)
    public static let deletionGutter = Color("DiffDeletionGutter", bundle: .module)

    /// 行高。行号槽与代码行必须用同一个值，否则两栏会错位。
    public static let codeLineHeight: CGFloat = 17
}
