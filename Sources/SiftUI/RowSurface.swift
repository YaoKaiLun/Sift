import SwiftUI

/// 侧边栏和文件列表共用的行外观：等高、通栏、直角、左侧强调条。
/// 两栏必须用同一个，否则选中态一边是胶囊一边是通栏，看着就是两个应用。
struct RowSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.horizontalPadding)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    fill
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: Theme.selectionBarWidth)
                    }
                }
            }
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if isSelected { return Theme.selectionFill }
        if isHovered { return Theme.hoverFill }
        return .clear
    }
}

extension View {
    func rowSurface(isSelected: Bool, isHovered: Bool,
                    height: CGFloat = Theme.rowHeight) -> some View {
        modifier(RowSurface(isSelected: isSelected, isHovered: isHovered, height: height))
    }
}

/// 分组标题行。通栏底、和文件名错开，组与组才分得开。
struct SectionHeaderRow: View {
    let title: String
    var count: Int?
    var isFirst: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(Theme.dividerColor)
                    .frame(height: 1)
                    .padding(.top, Theme.sectionTopGap)
            }
            HStack(spacing: Theme.rowSpacing) {
                Text(title)
                    .font(Theme.sectionFont)
                    .foregroundStyle(.secondary)
                if let count {
                    Text("\(count)")
                        .font(Theme.sectionFont.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .frame(height: Theme.sectionHeaderHeight)
            .background(Color.primary.opacity(0.08))
        }
    }
}
