import AppKit
import SwiftUI

/// 视觉规范的唯一出口。颜色一律走系统语义色，
/// 只有 diff 的增删色是自定义的——这两个必须为浅色与深色分别调校。
public enum Theme {
    public static let interfaceFont = Font.system(size: 13)
    public static let codeFont = Font.system(size: 12, design: .monospaced)
    public static let secondaryFont = Font.system(size: 11)
    public static let headerFont = Font.system(size: 13, weight: .semibold)
    public static let sectionFont = Font.system(size: 10, weight: .semibold)
    /// 侧边栏的仓库名是一级信息，不能和分组标签一样小。
    public static let repositoryFont = Font.system(size: 13, weight: .semibold)
    /// 文件列表里是整条相对路径，比普通界面文字小一号才不挤。
    public static let pathFont = Font.system(size: 12)

    public static let emptyTitleFont = Font.system(size: 13, weight: .medium)
    public static let emptyDescriptionFont = Font.system(size: 12)
    public static let emptySymbolFont = Font.system(size: 22)

    /// NSTextView 需要 NSFont 而不是 SwiftUI 的 Font。
    @MainActor
    public static let codeNSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // MARK: - 度量
    //
    // 三栏共用同一套数值。栏头等高才能让三栏的首行落在同一条水平线上，
    // 行等高才不会出现有的行一行、有的行两行的锯齿感。

    /// 顶栏要容得下红绿灯，所以比普通行高一档。
    public static let paneHeaderHeight: CGFloat = 38
    /// 红绿灯占掉的左侧宽度，栏头内容要从这里往右排。
    public static let trafficLightClearance: CGFloat = 62
    public static let sidebarFooterHeight: CGFloat = 36
    public static let rowHeight: CGFloat = 26
    public static let sectionHeaderHeight: CGFloat = 26
    /// 侧边栏比文件列表松一档：那里条目少，挤在一起反而难扫。
    public static let sidebarRowHeight: CGFloat = 30
    public static let sidebarGroupGap: CGFloat = 12
    public static let sectionTopGap: CGFloat = 10
    public static let horizontalPadding: CGFloat = 10
    public static let rowSpacing: CGFloat = 6
    /// 状态字母/图标所在的左侧固定栏。
    public static let statusColumnWidth: CGFloat = 16
    /// +/− 所在的右侧固定栏。
    public static let statsColumnWidth: CGFloat = 58
    /// 树视图每层缩进。
    public static let indentWidth: CGFloat = 12
    /// 选中行左侧的强调条宽度。
    public static let selectionBarWidth: CGFloat = 2

    // MARK: - 行状态

    public static let selectionFill = Color.accentColor.opacity(0.18)
    public static let hoverFill = Color.primary.opacity(0.06)

    /// 图标按钮的热区和圆角 hover。比通栏行 hover 略深，小目标才看得清。
    public static let iconHitSize: CGFloat = 24
    public static let iconCornerRadius: CGFloat = 5
    public static let iconHoverFill = Color.primary.opacity(0.10)
    public static let iconSelectedFill = Color.primary.opacity(0.14)

    // MARK: - 背景
    //
    // 每一栏都自己铺不透明底色。留空会透出系统侧栏的玻璃材质，
    // 那会给左栏带上一圈圆角外框。

    public static let chromeBackground = Color(nsColor: .windowBackgroundColor)
    public static let contentBackground = Color(nsColor: .textBackgroundColor)
    /// 侧边栏比另外两栏更暗一档，三栏才分得开。
    public static let sidebarBackground = Color("SidebarBackground", bundle: .module)

    // MARK: - 分栏线

    public static let dividerColor = Color.primary.opacity(0.10)
    public static let dividerActiveColor = Color.primary.opacity(0.32)

    public static let additionBackground = Color("DiffAddition", bundle: .module)
    public static let deletionBackground = Color("DiffDeletion", bundle: .module)
    public static let additionGutter = Color("DiffAdditionGutter", bundle: .module)
    public static let deletionGutter = Color("DiffDeletionGutter", bundle: .module)

    /// 行高。行号槽与代码行必须用同一个值，否则两栏会错位。
    public static let codeLineHeight: CGFloat = 17
}
