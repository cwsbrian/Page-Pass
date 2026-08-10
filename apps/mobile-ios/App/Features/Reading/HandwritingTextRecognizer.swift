import Foundation
import Vision

enum HandwritingOCRStatus: String, Codable, Sendable {
    case succeeded
    case lowConfidence = "low_confidence"
    case failed
}

struct HandwritingOCRLine: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let text: String
    let confidence: Float
}

struct HandwritingOCRResult: Equatable, Codable, Sendable {
    let status: HandwritingOCRStatus
    let lines: [HandwritingOCRLine]
    let supportedLanguageCodes: [String]
    let configuredLanguageCodes: [String]
    let requestRevision: Int
    let elapsedMilliseconds: Int

    var rawText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var averageConfidence: Float? {
        guard !lines.isEmpty else { return nil }
        return lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
    }

    var characterCount: Int {
        rawText.count
    }
}

enum HandwritingOCRQuality {
    static let lowConfidenceThreshold: Float = 0.5

    static func status(for lines: [HandwritingOCRLine]) -> HandwritingOCRStatus {
        guard !lines.isEmpty else { return .failed }
        let average = lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
        return average < lowConfidenceThreshold ? .lowConfidence : .succeeded
    }

    static func combinedTranscript(_ results: [HandwritingOCRResult]) -> String {
        results
            .map(\.rawText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

enum HandwritingTextRecognizerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The captured page could not be read."
        }
    }
}

actor HandwritingTextRecognizer {
    func recognize(imageData: Data) throws -> HandwritingOCRResult {
        guard !imageData.isEmpty else {
            throw HandwritingTextRecognizerError.invalidImage
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let supportedLanguages = try request.supportedRecognitionLanguages()
        let configuredLanguages = Self.preferredLanguages(from: supportedLanguages)
        if !configuredLanguages.isEmpty {
            request.recognitionLanguages = configuredLanguages
        }

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])

        let observations: [VNRecognizedTextObservation] = (request.results ?? []).sorted {
            let verticalDifference = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if verticalDifference > 0.02 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let lines: [HandwritingOCRLine] = observations.enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return HandwritingOCRLine(
                id: index,
                text: text,
                confidence: candidate.confidence
            )
        }

        return HandwritingOCRResult(
            status: HandwritingOCRQuality.status(for: lines),
            lines: lines,
            supportedLanguageCodes: supportedLanguages,
            configuredLanguageCodes: configuredLanguages,
            requestRevision: request.revision,
            elapsedMilliseconds: Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        )
    }

    private static func preferredLanguages(from supported: [String]) -> [String] {
        ["ko", "en"].compactMap { languagePrefix in
            supported.first { code in
                code == languagePrefix || code.hasPrefix("\(languagePrefix)-")
            }
        }
    }
}
