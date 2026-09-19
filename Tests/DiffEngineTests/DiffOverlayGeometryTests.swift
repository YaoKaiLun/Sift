import XCTest
import AppKit
@testable import SiftUI

@MainActor
final class DiffOverlayGeometryTests: XCTestCase {
    func testTopHunkHeaderSitsInTopHalfOfOverlay() throws {
        let harness = OverlayHarness(size: NSSize(width: 400, height: 300))
        let range = NSRange(location: 0, length: (harness.headerLine as NSString).length)
        let rect = try XCTUnwrap(DiffOverlayGeometry.headerRect(
            characterRange: range, textView: harness.textView, overlay: harness.overlay))

        XCTAssertGreaterThan(rect.height, 1)
        XCTAssertLessThan(rect.midY, harness.overlay.bounds.height / 2,
                           "flipped overlay: 文档顶部的 hunk 头应落在上半区，而不是窗口底部")
        XCTAssertTrue(rect.intersects(harness.overlay.bounds))
    }

    func testResizedOverlayStillKeepsTopHeaderVisible() throws {
        let harness = OverlayHarness(size: NSSize(width: 400, height: 300))
        harness.resize(to: NSSize(width: 900, height: 700))

        let range = NSRange(location: 0, length: (harness.headerLine as NSString).length)
        let rect = try XCTUnwrap(DiffOverlayGeometry.headerRect(
            characterRange: range, textView: harness.textView, overlay: harness.overlay))

        XCTAssertTrue(rect.intersects(harness.overlay.bounds),
                      "全屏/放大后，顶部 hunk 头仍应落在 overlay 可见范围内")
        XCTAssertLessThan(rect.midY, harness.overlay.bounds.height / 2)
    }

    func testLayoutFromZeroSizeKeepsHeaderInTopHalf() throws {
        let harness = OverlayHarness(size: .zero)
        harness.resize(to: NSSize(width: 400, height: 300))

        let range = NSRange(location: 0, length: (harness.headerLine as NSString).length)
        let rect = try XCTUnwrap(DiffOverlayGeometry.headerRect(
            characterRange: range, textView: harness.textView, overlay: harness.overlay))

        XCTAssertTrue(rect.intersects(harness.overlay.bounds),
                      "SwiftUI 先给 0 尺寸再 layout 时，按钮仍应出现在顶部 hunk 头上")
        XCTAssertLessThan(rect.midY, harness.overlay.bounds.height / 2)
    }

    func testActionRowAlignsToHeaderMidYAndTrailingEdge() {
        let header = NSRect(x: 0, y: 12, width: 400, height: 20)
        let frame = DiffOverlayGeometry.actionRowFrame(
            headerRect: header, size: NSSize(width: 80, height: 22),
            overlayBounds: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(frame.maxX, 392, accuracy: 0.5)
        XCTAssertEqual(frame.midY, header.midY, accuracy: 0.5)
    }

    func testSelectionActionSitsBelowAndDoesNotUseSelectionMaxX() {
        let selection = NSRect(x: 120, y: 40, width: 80, height: 16)
        let size = NSSize(width: 180, height: 24)
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frame = DiffOverlayGeometry.selectionActionFrame(
            selection: selection, size: size, in: bounds, flipped: true)

        XCTAssertEqual(frame.minX, 120, accuracy: 0.5)
        XCTAssertEqual(frame.minY, selection.maxY + 6, accuracy: 0.5)
        XCTAssertFalse(frame.intersects(selection),
                       "应落在选区下方，不能盖住同一行后半段代码")
    }

    func testSelectionActionClampsWhenSelectionIsNearTrailingEdge() {
        let selection = NSRect(x: 330, y: 40, width: 50, height: 16)
        let size = NSSize(width: 180, height: 24)
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frame = DiffOverlayGeometry.selectionActionFrame(
            selection: selection, size: size, in: bounds, flipped: true)
        XCTAssertEqual(frame.maxX, 392, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frame.minX, 8)
    }

    func testSelectionActionMovesAboveWhenBelowDoesNotFit() {
        let selection = NSRect(x: 20, y: 270, width: 80, height: 16)
        let size = NSSize(width: 160, height: 24)
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let frame = DiffOverlayGeometry.selectionActionFrame(
            selection: selection, size: size, in: bounds, flipped: true)
        XCTAssertEqual(frame.maxY, selection.minY - 6, accuracy: 0.5)
        XCTAssertFalse(frame.intersects(selection))
    }

    func testFullBleedBarStretchesToOverlayEdges() {
        let header = NSRect(x: 10, y: 12, width: 80, height: 24)
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let bar = DiffOverlayGeometry.fullBleedBar(from: header, overlayBounds: bounds)
        XCTAssertEqual(bar.minX, 0)
        XCTAssertEqual(bar.width, 400)
        XCTAssertEqual(bar.minY, 12)
        XCTAssertEqual(bar.height, 24)
    }

    func testHunkActionButtonMouseUpSendsAction() throws {
        let target = HunkActionClickTarget()
        let button = HunkActionButton(
            title: "解释",
            target: target,
            action: #selector(HunkActionClickTarget.clicked(_:)),
            hunkID: "h1")
        button.frame = NSRect(x: 0, y: 0, width: 48, height: 17)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.contentView?.addSubview(button)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 20, y: 8),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        button.mouseUp(with: event)
        XCTAssertTrue(target.fired, "自定义绘制的 hunk 按钮松开时必须发出 action")
    }

    func testHunkActionButtonConfirmationUpdatesTitle() {
        let button = HunkActionButton(
            title: "复制代码引用",
            target: nil,
            action: #selector(HunkActionClickTarget.clicked(_:)),
            hunkID: "copy-selection")
        button.setDisplayedTitle("已复制", confirmed: true)
        XCTAssertEqual(button.title, "已复制")
        XCTAssertEqual(button.attributedTitle.string, "已复制")
        let color = button.attributedTitle.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.labelColor)
        button.setDisplayedTitle("复制代码引用", confirmed: false)
        XCTAssertEqual(button.attributedTitle.string, "复制代码引用")
    }

    func testFileRowClickPolicyLetsContextMenuThrough() {
        XCTAssertTrue(FileRowClickPolicy.captures(type: .leftMouseDown, flags: []))
        XCTAssertTrue(FileRowClickPolicy.captures(type: .leftMouseUp, flags: []))
        XCTAssertFalse(FileRowClickPolicy.captures(type: .rightMouseDown, flags: []))
        XCTAssertFalse(FileRowClickPolicy.captures(type: .rightMouseUp, flags: []))
        XCTAssertFalse(FileRowClickPolicy.captures(type: .leftMouseDown, flags: .control))
        XCTAssertFalse(FileRowClickPolicy.captures(type: .mouseMoved, flags: []))
    }
}

private final class HunkActionClickTarget: NSObject {
    var fired = false

    @objc func clicked(_ sender: Any?) {
        fired = true
    }
}

/// 与产品一致：scroll view 和 flipped overlay 是兄弟，都铺满容器。
@MainActor
private final class OverlayHarness {
    let headerLine = "@@ -0,0 +1,3 @@\n"
    let holder: NSView
    let scrollView: NSScrollView
    let textView: NSTextView
    let overlay: FlippedOverlay

    init(size: NSSize) {
        holder = NSView(frame: NSRect(origin: .zero, size: size))
        scrollView = NSScrollView(frame: holder.bounds)
        scrollView.hasVerticalScroller = true
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: 1200))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.string = headerLine + String(repeating: "+line\n", count: 40)
        scrollView.documentView = textView
        holder.addSubview(scrollView)

        overlay = FlippedOverlay(frame: holder.bounds)
        overlay.autoresizingMask = [.width, .height]
        holder.addSubview(overlay, positioned: .above, relativeTo: scrollView)

        if size != .zero {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
    }

    func resize(to size: NSSize) {
        holder.setFrameSize(size)
        scrollView.frame = holder.bounds
        overlay.frame = holder.bounds
        if size.width > 0 {
            textView.textContainer?.containerSize = NSSize(
                width: size.width, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }
}

private final class FlippedOverlay: NSView {
    override var isFlipped: Bool { true }
}
