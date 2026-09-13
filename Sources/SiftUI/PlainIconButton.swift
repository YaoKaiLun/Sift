import SwiftUI

/// 图标热区：圆角 hover、选中略深、手指光标。
struct IconAffordance: View {
    let systemName: String
    var isSelected: Bool = false
    var isHovering: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: Theme.iconHitSize, height: Theme.iconHitSize)
            .background {
                RoundedRectangle(cornerRadius: Theme.iconCornerRadius, style: .continuous)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.iconCornerRadius, style: .continuous))
    }

    private var backgroundFill: Color {
        if isSelected { return Theme.iconSelectedFill }
        if isHovering { return Theme.iconHoverFill }
        return .clear
    }
}

/// 纯图标按钮，不带系统默认的圆角底。
struct PlainIconButton: View {
    let systemName: String
    var isSelected: Bool = false
    var help: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconAffordance(systemName: systemName,
                           isSelected: isSelected,
                           isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help(help ?? "")
    }
}

/// 两个互斥选项的图标切换，替代 segmented picker。
struct PlainIconToggle: View {
    @Binding var selection: Bool
    let falseIcon: String
    let trueIcon: String
    var help: String?

    var body: some View {
        HStack(spacing: 2) {
            PlainIconButton(systemName: falseIcon, isSelected: !selection) {
                selection = false
            }
            PlainIconButton(systemName: trueIcon, isSelected: selection) {
                selection = true
            }
        }
        .help(help ?? "")
    }
}

/// 菜单触发的图标。Menu 会吞掉 label 内部的 onHover，所以 hover 挂在外层容器上。
struct PlainIconMenu<Content: View>: View {
    let systemName: String
    var help: String?
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Menu(content: content) {
                Color.clear
                    .frame(width: Theme.iconHitSize, height: Theme.iconHitSize)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.iconCornerRadius,
                                                   style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)

            IconAffordance(systemName: systemName, isHovering: isHovering)
                .allowsHitTesting(false)
        }
        .frame(width: Theme.iconHitSize, height: Theme.iconHitSize)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help(help ?? "")
    }
}
