import CoreGraphics

/// 分栏热区的水平位置。热区以分界线为中心，不参与 HStack 布局。
enum SplitOverlayLayout {
    static func hitMinXs(showsSidebar: Bool, sidebarWidth: CGFloat,
                         fileListWidth: CGFloat, hitWidth: CGFloat = 11)
        -> (sidebar: CGFloat?, fileList: CGFloat) {
        let half = hitWidth / 2
        let fileListBoundary = (showsSidebar ? sidebarWidth : 0) + fileListWidth
        return (
            showsSidebar ? sidebarWidth - half : nil,
            fileListBoundary - half
        )
    }
}
