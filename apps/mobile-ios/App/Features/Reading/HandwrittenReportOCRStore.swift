import Foundation
import Observation
import OSLog

enum HandwrittenReportPageState: Equatable {
    case pending
    case processing
    case completed(HandwritingOCRResult)
    case failed(String)
}

struct HandwrittenReportPage: Identifiable, Equatable {
    let id: UUID
    let imageData: Data
    var ocrRevision: Int
    var state: HandwrittenReportPageState
}

@MainActor
@Observable
final class HandwrittenReportOCRStore {
    private(set) var pages: [HandwrittenReportPage] = []
    private(set) var correctedTranscript = ""
    private(set) var isTranscriptEdited = false
    private(set) var errorMessage: String?
    private(set) var isProcessing = false

    private let recognizer = HandwritingTextRecognizer()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pagepass.app",
        category: "HandwrittenReportOCR"
    )
    private var activeRunID: UUID?

    var completedResults: [HandwritingOCRResult] {
        pages.compactMap { page in
            guard case let .completed(result) = page.state else { return nil }
            return result
        }
    }

    var rawTranscript: String {
        HandwritingOCRQuality.combinedTranscript(completedResults)
    }

    var koreanRecognitionSupported: Bool? {
        targetLanguageSupport(prefix: "ko")
    }

    var englishRecognitionSupported: Bool? {
        targetLanguageSupport(prefix: "en")
    }

    var totalElapsedMilliseconds: Int {
        completedResults.reduce(0) { $0 + $1.elapsedMilliseconds }
    }

    func recognizeNewPages(_ imageData: [Data]) async {
        guard !imageData.isEmpty else { return }

        let runID = UUID()
        activeRunID = runID
        pages = imageData.map {
            HandwrittenReportPage(
                id: UUID(),
                imageData: $0,
                ocrRevision: 0,
                state: .pending
            )
        }
        correctedTranscript = ""
        isTranscriptEdited = false
        errorMessage = nil
        isProcessing = true

        for pageID in pages.map(\.id) {
            guard activeRunID == runID else { return }
            await recognizePage(id: pageID)
        }

        guard activeRunID == runID else { return }
        isProcessing = false
    }

    func retryPage(id: UUID) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        await recognizePage(id: id)
        isProcessing = false
    }

    func updateCorrectedTranscript(_ value: String) {
        correctedTranscript = value
        isTranscriptEdited = value != rawTranscript
    }

    func resetCorrection() {
        correctedTranscript = rawTranscript
        isTranscriptEdited = false
    }

    func reportCaptureError(_ message: String) {
        errorMessage = message
    }

    func restore(
        pages: [HandwrittenReportPage],
        correctedTranscript: String,
        isTranscriptEdited: Bool
    ) {
        activeRunID = nil
        self.pages = pages
        self.correctedTranscript = correctedTranscript
        self.isTranscriptEdited = isTranscriptEdited
        errorMessage = nil
        isProcessing = false
    }

    func clear() {
        activeRunID = nil
        pages = []
        correctedTranscript = ""
        isTranscriptEdited = false
        errorMessage = nil
        isProcessing = false
    }

    private func recognizePage(id: UUID) async {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].ocrRevision += 1
        pages[index].state = .processing
        let revision = pages[index].ocrRevision
        let imageData = pages[index].imageData

        logger.notice(
            "ocr_page_start page=\(index + 1, privacy: .public) revision=\(revision, privacy: .public) bytes=\(imageData.count, privacy: .public)"
        )

        do {
            let result = try await recognizer.recognize(imageData: imageData)
            guard let currentIndex = pages.firstIndex(where: { $0.id == id }),
                  pages[currentIndex].ocrRevision == revision else { return }
            pages[currentIndex].state = .completed(result)
            syncCorrectionIfUnedited()
            logger.notice(
                "ocr_page_complete page=\(currentIndex + 1, privacy: .public) revision=\(revision, privacy: .public) status=\(result.status.rawValue, privacy: .public) lines=\(result.lines.count, privacy: .public) characters=\(result.characterCount, privacy: .public) elapsed_ms=\(result.elapsedMilliseconds, privacy: .public)"
            )
        } catch {
            guard let currentIndex = pages.firstIndex(where: { $0.id == id }),
                  pages[currentIndex].ocrRevision == revision else { return }
            let message = error.localizedDescription
            pages[currentIndex].state = .failed(message)
            errorMessage = message
            logger.error(
                "ocr_page_failed page=\(currentIndex + 1, privacy: .public) revision=\(revision, privacy: .public) error=\(message, privacy: .public)"
            )
        }
    }

    private func syncCorrectionIfUnedited() {
        guard !isTranscriptEdited else { return }
        correctedTranscript = rawTranscript
    }

    private func targetLanguageSupport(prefix: String) -> Bool? {
        guard let result = completedResults.first else { return nil }
        return result.supportedLanguageCodes.contains {
            $0 == prefix || $0.hasPrefix("\(prefix)-")
        }
    }
}
