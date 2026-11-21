import AppKit
import Vision

@MainActor
final class OCRService {
    func recognize(image: CGImage, languages: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: Self.assemble(observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Groups Vision observations into lines and joins them in reading order.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        struct Line {
            var minY: CGFloat
            var maxY: CGFloat
            var segments: [(minX: CGFloat, text: String)]

            var midY: CGFloat { (minY + maxY) / 2 }
        }

        var lines: [Line] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            let text = candidate.string

            if let index = lines.firstIndex(where: { abs($0.midY - box.midY) < 0.012 }) {
                lines[index].segments.append((box.minX, text))
                lines[index].minY = min(lines[index].minY, box.minY)
                lines[index].maxY = max(lines[index].maxY, box.maxY)
            } else {
                lines.append(Line(minY: box.minY, maxY: box.maxY, segments: [(box.minX, text)]))
            }
        }

        lines.sort { $0.midY > $1.midY }

        let output = lines.map { line -> String in
            let segments = line.segments.sorted { $0.minX < $1.minX }
            var result = ""
            var previousText: String?
            for segment in segments {
                if let previousText {
                    result += needsSpace(previousText, segment.text) ? " " : ""
                }
                result += segment.text
                previousText = segment.text
            }
            return result.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }

        return output.joined(separator: "\n")
    }

    private static func needsSpace(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if isCJK(last) || isCJK(first) { return false }
        return true
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}

extension OCRService {
    /// Splits a rectangle out of a captured screenshot.
    static func crop(_ screens: [CGDirectDisplayID: CapturedScreen], globalRect: CGRect) -> CGImage? {
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        guard let screen = screens.values.first(where: { $0.frame.contains(center) })
            ?? screens.values.first else {
            return nil
        }

        let scale = screen.scale
        let localX = (globalRect.minX - screen.frame.minX) * scale
        let localY = (screen.frame.height - (globalRect.minY - screen.frame.minY) - globalRect.height) * scale
        let pixelRect = CGRect(
            x: localX,
            y: localY,
            width: globalRect.width * scale,
            height: globalRect.height * scale
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: screen.image.width, height: screen.image.height))

        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return screen.image.cropping(to: pixelRect)
    }
}
