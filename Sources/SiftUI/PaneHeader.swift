import SwiftUI

/// 三栏共用的栏头。高度写死在 Theme 里，三栏才会对齐到同一条线。
///
/// `leadingInset` 用来给左上角红绿灯让位：栏头本身顶到窗口上沿，
/// 只把内容往右推，这样顶部只有一行，而不是「红绿灯一条 + 栏头一条」。
struct PaneHeader<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsDivider: Bool
    var leadingInset: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if leadingInset > 0 {
                    Color.clear.frame(width: leadingInset)
                }
                leading
                if !title.isEmpty {
                    Text(title)
                        .font(Theme.headerFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.secondaryFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .frame(height: Theme.paneHeaderHeight)
            if showsDivider {
                Divider()
            }
        }
    }
}

extension PaneHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         showsDivider: Bool = true,
         leadingInset: CGFloat = 0) {
        self.init(title: title,
                  subtitle: subtitle,
                  showsDivider: showsDivider,
                  leadingInset: leadingInset) {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }
}

extension PaneHeader where Leading == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         showsDivider: Bool = true,
         leadingInset: CGFloat = 0,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title,
                  subtitle: subtitle,
                  showsDivider: showsDivider,
                  leadingInset: leadingInset) {
            EmptyView()
        } trailing: {
            trailing()
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         showsDivider: Bool = true,
         leadingInset: CGFloat = 0,
         @ViewBuilder leading: () -> Leading) {
        self.init(title: title,
                  subtitle: subtitle,
                  showsDivider: showsDivider,
                  leadingInset: leadingInset) {
            leading()
        } trailing: {
            EmptyView()
        }
    }
}
