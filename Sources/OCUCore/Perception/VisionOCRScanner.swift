import Foundation
import Vision
import CoreGraphics

public final class VisionOCRScanner: @unchecked Sendable {
    public static let shared = VisionOCRScanner()

    private init() {}

    /// Converts a Vision normalized rect (origin at bottom-left, [0,1]) into top-left screen logical coordinates.
    public static func convertNormalizedVisionRect(
        _ normalizedBox: CGRect,
        in screenBounds: ScreenRect
    ) -> ScreenRect {
        let x = screenBounds.x + Double(normalizedBox.origin.x) * screenBounds.width
        let y = screenBounds.y + (1.0 - Double(normalizedBox.origin.y + normalizedBox.size.height)) * screenBounds.height
        let w = Double(normalizedBox.size.width) * screenBounds.width
        let h = Double(normalizedBox.size.height) * screenBounds.height
        return ScreenRect(x: x, y: y, width: w, height: h)
    }

    /// Merges OCR elements into existing AX elements, deduplicating boxes that already overlap an AX element
    /// and re-indexing all elements sequentially (`@e1`, `@e2`, ...).
    public static func mergeElements(
        axElements: [UIElementRef],
        ocrCandidates: [UIElementRef],
        maxTotalElements: Int = 240
    ) -> [UIElementRef] {
        var combined = axElements
        for candidate in ocrCandidates {
            guard combined.count < maxTotalElements else { break }
            let isCovered = axElements.contains { ax in
                candidate.frame.overlapsSignificantly(with: ax.frame)
            }
            if !isCovered {
                combined.append(candidate)
            }
        }

        // Re-index @e1 .. @eN in order (AX first, then supplemental OCR sorted top-to-bottom)
        for idx in combined.indices {
            combined[idx].ref = "@e\(idx + 1)"
        }
        return combined
    }

    public func recognizeTextElements(
        in cgImage: CGImage,
        screenBounds: ScreenRect,
        appName: String,
        pid: Int32,
        windowTitle: String?,
        minimumConfidence: Float = 0.45,
        maxCandidates: Int = 120
    ) -> [UIElementRef] {
        var candidates: [UIElementRef] = []

        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else {
                return
            }
            for obs in observations {
                guard let topCandidate = obs.topCandidates(1).first,
                      topCandidate.confidence >= minimumConfidence else {
                    continue
                }
                let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 100 else { continue }

                let rect = Self.convertNormalizedVisionRect(obs.boundingBox, in: screenBounds)
                guard rect.width >= 8, rect.height >= 8 else { continue }

                let element = UIElementRef(
                    ref: "",
                    source: .ocr,
                    role: "ocrText",
                    label: text,
                    value: nil,
                    frame: rect,
                    enabled: true,
                    focused: false,
                    appName: appName,
                    pid: pid,
                    windowTitle: windowTitle,
                    confidence: Double((topCandidate.confidence * 100).rounded() / 100)
                )
                candidates.append(element)
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        candidates.sort { a, b in
            let rowA = Int(a.frame.y / 18.0)
            let rowB = Int(b.frame.y / 18.0)
            if rowA != rowB {
                return rowA < rowB
            }
            return a.frame.x < b.frame.x
        }

        return Array(candidates.prefix(maxCandidates))
    }
}
