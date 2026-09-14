import AppKit
import SwiftUI

/// 在文件列表安装本地方向键监听。输入框放行；Diff 文本视图上的上下键切文件。
struct FileListKeyMonitor: NSViewRepresentable {
    var orderedIDs: [String]
    var onMove: (Int, Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.orderedIDs = orderedIDs
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.orderedIDs = orderedIDs
        nsView.onMove = onMove
    }

    final class MonitorView: NSView {
        var orderedIDs: [String] = []
        var onMove: ((Int, Bool) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                install()
            } else {
                remove()
            }
        }

        deinit { remove() }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            let down: UInt16 = 125
            let up: UInt16 = 126
            guard event.keyCode == down || event.keyCode == up else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.option) { return event }
            if let responder = NSApp.keyWindow?.firstResponder {
                if responder is NSTextField || responder is NSSecureTextField {
                    return event
                }
                if let textView = responder as? NSTextView, !(textView is DiffCopyTextView) {
                    return event
                }
            }
            let delta = event.keyCode == down ? 1 : -1
            onMove?(delta, flags.contains(.shift))
            return nil
        }
    }
}
