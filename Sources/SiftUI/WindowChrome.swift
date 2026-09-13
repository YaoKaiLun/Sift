import AppKit
import SwiftUI

public enum WindowChrome {
    public static func apply(to window: NSWindow) {
        // 设置窗保持系统标题栏，不要套主窗口的无标题栏样式。
        guard window.titleVisibility == .hidden
                || window.styleMask.contains(.fullSizeContentView) else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenPrimary)
        if let sidebar = NSColor(named: "SidebarBackground", bundle: .module) {
            window.backgroundColor = sidebar
        }
        centerTrafficLights(in: window)
    }

    /// 红绿灯默认按 28pt 标准标题栏居中，而我们的顶栏有 `paneHeaderHeight` 高，
    /// 不挪的话它们会比同一行的标题高出几个点。全屏时交还给系统摆。
    private static func centerTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let titlebar = buttons.first?.superview else { return }

        let centerY = Theme.paneHeaderHeight / 2
        for button in buttons {
            let height = button.frame.height
            let y = titlebar.isFlipped
                ? centerY - height / 2
                : titlebar.bounds.height - centerY - height / 2
            guard abs(button.frame.origin.y - y) > 0.5 else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
        }
    }

    public static func applyToAllWindows() {
        for window in NSApplication.shared.windows where window.canBecomeKey {
            apply(to: window)
        }
    }
}

/// 透明标题栏 + 内容顶到窗口上沿，红绿灯浮在侧栏上方。
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.applyIfNeeded()
    }
}

final class WindowChromeView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    override func layout() {
        super.layout()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard let window else { return }
        WindowChrome.apply(to: window)
    }
}

/// 全屏时红绿灯会收起，顶栏左侧那段让位就得收回去，否则标题白白缩进一块。
private struct FullScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWindowFullScreen: Bool {
        get { self[FullScreenKey.self] }
        set { self[FullScreenKey.self] = newValue }
    }
}

/// 让位宽度：非全屏给红绿灯留位，全屏归零。
extension EnvironmentValues {
    var trafficLightInset: CGFloat {
        isWindowFullScreen ? 0 : Theme.trafficLightClearance
    }
}

public extension View {
    func siftWindowChrome() -> some View {
        background {
            WindowChromeConfigurator()
                .frame(width: 1, height: 1)
        }
    }
}
