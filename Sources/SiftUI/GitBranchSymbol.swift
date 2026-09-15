import SwiftUI

/// 侧栏主工作树的 Git 分支符号。线宽和节点按 13×14 画，和 `arrow.triangle.branch` 11–12pt 同粗细。
struct GitBranchSymbol: View {
    var body: some View {
        Canvas { context, size in
            let lineWidth = max(1.1, size.width * 0.085)
            let radius = max(1.1, size.width * 0.09)
            let bottom = CGPoint(x: size.width * 0.30, y: size.height * 0.82)
            let stemTop = CGPoint(x: size.width * 0.30, y: size.height * 0.22)
            let junction = CGPoint(x: size.width * 0.30, y: size.height * 0.48)
            let tip = CGPoint(x: size.width * 0.80, y: size.height * 0.18)

            var stem = Path()
            stem.move(to: bottom)
            stem.addLine(to: stemTop)

            var branch = Path()
            branch.move(to: junction)
            branch.addQuadCurve(to: tip, control: CGPoint(x: junction.x + size.width * 0.04, y: tip.y))

            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            context.stroke(stem, with: .foreground, style: stroke)
            context.stroke(branch, with: .foreground, style: stroke)
            for point in [bottom, stemTop, tip] {
                let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .foreground)
            }
        }
        .accessibilityLabel("分支")
    }
}
