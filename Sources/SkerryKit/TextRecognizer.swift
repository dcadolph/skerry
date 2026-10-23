import CoreGraphics
import Foundation
import ImageIO
import Vision

/// TextRecognizer turns an image into text with on-device Vision OCR, so a photo of a sign, a
/// receipt, or a page becomes note text without anything leaving the device.
public enum TextRecognizer {
    /// Errors raised while recognizing text.
    public enum RecognizeError: Error, Equatable {
        /// The image bytes could not be decoded into an image.
        case undecodable
        /// Vision could not run the recognition request.
        case failed
    }

    /// Recognizes text in image data and returns it as newline-joined lines, ordered top to
    /// bottom, taking the most confident candidate for each line. Runs entirely on device.
    ///
    /// This call is synchronous and does real work, so run it off the main thread.
    public static func recognize(imageData: Data, languages: [String] = []) throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RecognizeError.undecodable }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognizeError.failed
        }

        // Vision's coordinate origin is bottom-left, so a higher midY sits higher on the page and
        // should read first.
        let observations = (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
