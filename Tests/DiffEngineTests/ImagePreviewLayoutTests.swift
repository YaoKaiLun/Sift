import XCTest
import AppKit
@testable import SiftUI

final class ImagePreviewLayoutTests: XCTestCase {
    func testDoesNotUpscaleSmallImage() {
        let size = ImagePreviewLayout.fittedSize(
            pixelWidth: 16, pixelHeight: 16, maxWidth: 400)
        XCTAssertEqual(size, CGSize(width: 16, height: 16))
    }

    func testScalesDownToFitColumnWidth() {
        let size = ImagePreviewLayout.fittedSize(
            pixelWidth: 800, pixelHeight: 400, maxWidth: 400)
        XCTAssertEqual(size, CGSize(width: 400, height: 200))
    }

    func testPixelSizeReadsBitmapPixelsNotPoints() throws {
        let image = try XCTUnwrap(NSImage(data: png1x1))
        let pixels = ImagePreviewLayout.pixelSize(of: image)
        XCTAssertEqual(pixels.width, 1)
        XCTAssertEqual(pixels.height, 1)
    }
}

private let png1x1 = Data([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
    0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 0, 0,
    3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73, 69, 78, 68,
    174, 66, 96, 130
])
