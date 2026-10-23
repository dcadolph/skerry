import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing

@testable import SkerryKit

@Suite struct TextRecognizerTests {
    /// Renders a word in large black type on a white field and returns it as PNG data, so the
    /// recognizer has clean text to read.
    private func png(of word: String) -> Data {
        let width = 640
        let height = 200
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, word as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, context)
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func recognizesClearText() throws {
        let result = try TextRecognizer.recognize(imageData: png(of: "SKERRY"))
        #expect(result.uppercased().contains("SKERRY"))
    }

    @Test func rejectsUndecodableData() {
        #expect(throws: TextRecognizer.RecognizeError.undecodable) {
            try TextRecognizer.recognize(imageData: Data([0x00, 0x01, 0x02, 0x03]))
        }
    }
}
