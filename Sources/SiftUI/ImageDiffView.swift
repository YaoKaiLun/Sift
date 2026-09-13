import SwiftUI
import AppKit
import GitKit

enum ImagePreviewLayout {
    static func fittedSize(pixelWidth: Int, pixelHeight: Int, maxWidth: CGFloat) -> CGSize {
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        guard width > 0, height > 0, maxWidth > 0 else { return .zero }
        let scale = min(1, maxWidth / width)
        return CGSize(width: width * scale, height: height * scale)
    }

    static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        if let representation = image.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return (representation.pixelsWide, representation.pixelsHigh)
        }
        return (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
    }
}

struct ImageDiffView: View {
    let image: ImageDiff

    var body: some View {
        let old = DisplaySide(image.old)
        let new = DisplaySide(image.new)
        if old == nil && new == nil {
            PaneEmptyState(title: "二进制文件", systemImage: "doc.badge.gearshape")
        } else if let old, let new {
            HStack(spacing: 0) {
                column(title: "旧", side: old)
                Divider()
                column(title: "新", side: new)
            }
        } else if let old {
            column(title: "旧", side: old)
        } else if let new {
            column(title: "新", side: new)
        }
    }

    private func column(title: String, side: DisplaySide) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 10) {
                    Text(title)
                        .font(Theme.sectionFont)
                        .foregroundStyle(.secondary)
                    switch side {
                    case .picture(let nsImage, let byteCount):
                        let pixels = ImagePreviewLayout.pixelSize(of: nsImage)
                        let fitted = ImagePreviewLayout.fittedSize(
                            pixelWidth: pixels.width,
                            pixelHeight: pixels.height,
                            maxWidth: max(0, geo.size.width - 48))
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                            .background(CheckerboardBackground())
                        Text("\(pixels.width) × \(pixels.height) · \(Self.byteText(byteCount))")
                            .font(Theme.secondaryFont)
                            .foregroundStyle(.secondary)
                    case .tooLarge(let byteCount):
                        Text("图片过大，无法预览")
                            .font(Theme.emptyTitleFont)
                            .foregroundStyle(.secondary)
                        Text(Self.byteText(byteCount))
                            .font(Theme.secondaryFont)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func byteText(_ count: Int) -> String {
        let megabyte = 1024 * 1024
        if count >= megabyte {
            return "\(count / megabyte) MB"
        }
        if count >= 1024 {
            return "\(count / 1024) KB"
        }
        return "\(count) B"
    }
}

private enum DisplaySide {
    case picture(NSImage, byteCount: Int)
    case tooLarge(byteCount: Int)

    init?(_ side: ImageSide?) {
        switch side {
        case .none:
            return nil
        case .tooLarge(let count):
            self = .tooLarge(byteCount: count)
        case .bytes(let data):
            guard let image = NSImage(data: data) else { return nil }
            self = .picture(image, byteCount: data.count)
        }
    }
}

private struct CheckerboardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            let dark = colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.black.opacity(0.08)
            let light = colorScheme == .dark
                ? Color.white.opacity(0.04)
                : Color.black.opacity(0.03)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: cell, height: cell)
                    context.fill(Path(rect), with: .color((row + col).isMultiple(of: 2) ? light : dark))
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
    }
}
