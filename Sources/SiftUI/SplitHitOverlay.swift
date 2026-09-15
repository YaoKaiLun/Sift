import AppKit
import SwiftUI

/// 窗口级分栏拖动。不往 `NSHostingView` 里塞子视图——它的 `hitTest` 不会问这些额外层。
struct SplitDragMonitor: NSViewRepresentable {
    var showsSidebar: Bool
    var sidebarWidth: CGFloat
    var fileListWidth: CGFloat
    var onSidebarWidth: (CGFloat) -> Void
    var onFileListWidth: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onActiveChange: (SplitOverlayLayout.Divider?) -> Void

    func makeNSView(context: Context) -> SplitDragMonitorView {
        SplitDragMonitorView()
    }

    func updateNSView(_ nsView: SplitDragMonitorView, context: Context) {
        nsView.showsSidebar = showsSidebar
        nsView.sidebarWidth = sidebarWidth
        nsView.fileListWidth = fileListWidth
        nsView.onSidebarWidth = onSidebarWidth
        nsView.onFileListWidth = onFileListWidth
        nsView.onDragEnded = onDragEnded
        nsView.onActiveChange = onActiveChange
        nsView.installMonitorIfNeeded()
    }
}

final class SplitDragMonitorView: NSView {
    var showsSidebar = true
    var sidebarWidth: CGFloat = 0
    var fileListWidth: CGFloat = 0
    var sidebarRange: ClosedRange<CGFloat> = 180...340
    var fileListRange: ClosedRange<CGFloat> = 240...520
    var onSidebarWidth: ((CGFloat) -> Void)?
    var onFileListWidth: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onActiveChange: ((SplitOverlayLayout.Divider?) -> Void)?

    private var monitor: Any?
    private var dragTarget: SplitOverlayLayout.Divider?
    private var dragStartWidth: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var hoverTarget: SplitOverlayLayout.Divider?
    private var didPushCursor = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeMonitor()
            popCursor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func installMonitorIfNeeded() {
        guard window != nil else { return }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .cursorUpdate]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        guard let host = window?.contentView else { return event }
        let x = host.convert(event.locationInWindow, from: nil).x

        switch event.type {
        case .leftMouseDown:
            guard let target = divider(at: x) else { return event }
            dragTarget = target
            dragStartX = event.locationInWindow.x
            dragStartWidth = target == .sidebar ? sidebarWidth : fileListWidth
            reportActive(target)
            return nil
        case .leftMouseDragged:
            guard let dragTarget else { return event }
            let proposed = dragStartWidth + (event.locationInWindow.x - dragStartX)
            let range = dragTarget == .sidebar ? sidebarRange : fileListRange
            let clamped = min(max(proposed, range.lowerBound), range.upperBound)
            switch dragTarget {
            case .sidebar:
                sidebarWidth = clamped
                onSidebarWidth?(clamped)
            case .fileList:
                fileListWidth = clamped
                onFileListWidth?(clamped)
            }
            NSCursor.resizeLeftRight.set()
            return nil
        case .leftMouseUp:
            guard dragTarget != nil else { return event }
            dragTarget = nil
            reportActive(divider(at: x))
            onDragEnded?()
            return nil
        case .mouseMoved, .cursorUpdate:
            if dragTarget != nil || divider(at: x) != nil {
                reportActive(dragTarget ?? divider(at: x))
                NSCursor.resizeLeftRight.set()
                return nil
            }
            reportActive(nil)
            return event
        default:
            return event
        }
    }

    private func divider(at x: CGFloat) -> SplitOverlayLayout.Divider? {
        SplitOverlayLayout.divider(
            atX: x,
            showsSidebar: showsSidebar,
            sidebarWidth: sidebarWidth,
            fileListWidth: fileListWidth)
    }

    private func reportActive(_ target: SplitOverlayLayout.Divider?) {
        if hoverTarget != target {
            hoverTarget = target
            onActiveChange?(target)
        }
        if dragTarget != nil || target != nil {
            NSCursor.resizeLeftRight.set()
            didPushCursor = true
        } else {
            popCursor()
        }
    }

    private func popCursor() {
        guard didPushCursor else { return }
        NSCursor.arrow.set()
        didPushCursor = false
    }
}
