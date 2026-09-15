import CoreGraphics

/// 分栏热区的水平位置。热区以分界线为中心，不参与 HStack 布局。
enum SplitOverlayLayout {
    enum Divider: Equatable {
        case sidebar
        case fileList
    }

    /// 视觉线仍是 1pt。热区 16pt，以分界线为中心。
    static let defaultHitWidth: CGFloat = 16

    static func hitMinXs(showsSidebar: Bool, sidebarWidth: CGFloat,
                         fileListWidth: CGFloat, hitWidth: CGFloat = defaultHitWidth)
        -> (sidebar: CGFloat?, fileList: CGFloat) {
        let half = hitWidth / 2
        let fileListBoundary = (showsSidebar ? sidebarWidth : 0) + fileListWidth
        return (
            showsSidebar ? sidebarWidth - half : nil,
            fileListBoundary - half
        )
    }

    static func divider(atX x: CGFloat, showsSidebar: Bool, sidebarWidth: CGFloat,
                        fileListWidth: CGFloat, hitWidth: CGFloat = defaultHitWidth) -> Divider? {
        let hits = hitMinXs(showsSidebar: showsSidebar, sidebarWidth: sidebarWidth,
                            fileListWidth: fileListWidth, hitWidth: hitWidth)
        if let minX = hits.sidebar, x >= minX && x < minX + hitWidth {
            return .sidebar
        }
        if x >= hits.fileList && x < hits.fileList + hitWidth {
            return .fileList
        }
        return nil
    }

    /// overlay 热区有一半伸进右栏。AppKit `NSTextView` 会挡住 SwiftUI overlay，
    /// 右栏要把这段命中让出去。
    static func shouldPassthroughLeadingHit(_ x: CGFloat, hitWidth: CGFloat = defaultHitWidth) -> Bool {
        x < hitWidth / 2
    }
}
