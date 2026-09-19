import AppKit
import SwiftUI

/// SwiftUI `onTapGesture` 在 NSTextView 持有焦点时，第一次点击只用来聚焦。
/// 这层 NSView `acceptsFirstMouse`，左键第一下就能选中；右键 / Control-点击穿透给 SwiftUI 菜单。
struct FirstMouseClickCatcher: NSViewRepresentable {
    var onClick: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onClick = onClick
    }

    final class CatcherView: NSView {
        var onClick: ((Int) -> Void)?

        override var isOpaque: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            if let event = NSApp.currentEvent,
               !FileRowClickPolicy.captures(type: event.type, flags: event.modifierFlags) {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(event.clickCount)
        }
    }
}

enum FileRowClickPolicy {
    /// 只拦左键。右键 / Control-点击 / 移动都交给 SwiftUI，菜单和 hover 才还在。
    static func captures(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return !flags.contains(.control)
        default:
            return false
        }
    }
}
