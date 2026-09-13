import AppKit
import SwiftUI

extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.set()
            }
        }
    }

    func pointingHandCursor() -> some View {
        hoverCursor(.pointingHand)
    }
}
