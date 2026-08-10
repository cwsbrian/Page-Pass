import CryptoKit
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ReadingSubmissionStore {
    private(set) var isSubmitting = false
    private(set) var progressMessage: String?
    private(set) var submittedReport: ReadingSubmissionResponse?
    private(set) var recoverableDraft: RecoverableReadingDraft?
    private(set) var errorMessage: String?

    private let credentials = DeviceCredentialStore()
    private let recoveryStore: ReadingDraftRecoveryStore

    init(recoveryStore: ReadingDraftRecoveryStore = ReadingDraftRecoveryStore()) {
        self.recoveryStore = recoveryStore
        do {
            recoverableDraft = try recoveryStore.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var isSubmitted: Bool {
        submittedReport?.status == "pending"
    }

    var hasRecoverableDraft: Bool {
        recoverableDraft != nil
    }

    func submit(
        bookTitle: String,
        author: String,
        pages: [HandwrittenReportPage],
        rawTranscript: String,
        correctedTranscript: String,
        isTranscriptEdited: Bool,
        supersedesSubmissionID: String? = nil
    ) async {
        guard !isSubmitting else { return }
        let title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Enter the book title."
            return
        }
        guard !pages.isEmpty else {
            errorMessage = "Scan at least one handwritten page."
            return
        }
        guard recoverableDraft == nil else {
            errorMessage = ReadingDraftRecoveryError.existingDraft.localizedDescription
            return
        }

        await performSubmission {
            let preparedPages = try pages.enumerated().map { index, page in
                let data = try normalizedJPEG(page.imageData)
                let ocr = try recoverablePage(
                    page,
                    pageOrder: index,
                    imageData: data
                )
                return (data: data, ocr: ocr)
            }
            let draft = try recoveryStore.create(
                bookTitle: title,
                author: normalizedOptionalText(author),
                rawTranscript: rawTranscript,
                correctedTranscript: correctedTranscript,
                isTranscriptEdited: isTranscriptEdited,
                supersedesSubmissionID: supersedesSubmissionID,
                pages: preparedPages
            )
            recoverableDraft = draft
            try await upload(draft)
        }
    }

    func resumeRecoverableDraft() async {
        guard !isSubmitting, let draft = recoverableDraft else { return }
        await performSubmission {
            try await upload(draft)
        }
    }

    func replacePagesAndResubmit(
        submission: ReadingSubmissionResponse,
        pages: [HandwrittenReportPage],
        rawTranscript: String,
        correctedTranscript: String,
        isTranscriptEdited: Bool
    ) async {
        guard !isSubmitting else { return }
        guard submission.status == "changes_requested" else {
            errorMessage = ReadingSubmissionError.draftNotEditable.localizedDescription
            return
        }
        guard !pages.isEmpty else {
            errorMessage = "Choose at least one replacement page."
            return
        }
        guard recoverableDraft == nil else {
            errorMessage = ReadingDraftRecoveryError.existingDraft.localizedDescription
            return
        }
        await performSubmission {
            let preparedPages = try pages.enumerated().map { index, page in
                let data = try normalizedJPEG(page.imageData)
                return (
                    data: data,
                    ocr: try recoverablePage(
                        page,
                        pageOrder: index,
                        imageData: data
                    )
                )
            }
            let draft = try recoveryStore.create(
                bookTitle: submission.bookTitle ?? "Untitled Book",
                author: submission.author,
                rawTranscript: rawTranscript,
                correctedTranscript: correctedTranscript,
                isTranscriptEdited: isTranscriptEdited,
                serverSubmissionID: submission.id,
                transition: "resubmit",
                pages: preparedPages
            )
            recoverableDraft = draft
            try await upload(draft)
        }
    }

    func discardRecoverableDraft() async {
        guard !isSubmitting, let draft = recoverableDraft else { return }
        await performSubmission {
            if let submissionID = draft.serverSubmissionID,
               draft.transition != "resubmit" {
                guard let credential = try await credentials.load() else {
                    throw ReadingSubmissionError.deviceNotPaired
                }
                let client = try PagePassRuntimeConfiguration.apiClient(
                    serverURLString: PagePassRuntimeConfiguration.serverURLString
                )
                do {
                    let remote = try await client.childReadingSubmission(
                        submissionID: submissionID,
                        deviceCredential: credential
                    )
                    if remote.status == "draft" {
                        try await client.deleteReadingDraft(
                            submissionID: submissionID,
                            deviceCredential: credential
                        )
                    } else {
                        submittedReport = remote
                    }
                } catch let error as PagePassAPIClient.ClientError {
                    guard error.statusCode == 404 else { throw error }
                }
            }
            try recoveryStore.remove()
            recoverableDraft = nil
        }
    }

    func clear() {
        submittedReport = nil
        errorMessage = nil
        progressMessage = nil
    }

    private func performSubmission(
        _ operation: () async throws -> Void
    ) async {
        isSubmitting = true
        errorMessage = nil
        submittedReport = nil
        defer {
            isSubmitting = false
            progressMessage = nil
        }

        do {
            try await operation()
        } catch {
            let suffix = recoverableDraft == nil
                ? ""
                : " Your report is saved on this device. Retry when the connection is available."
            errorMessage = error.localizedDescription + suffix
        }
    }

    private func upload(_ initialDraft: RecoverableReadingDraft) async throws {
        guard let credential = try await credentials.load() else {
            throw ReadingSubmissionError.deviceNotPaired
        }
        let client = try PagePassRuntimeConfiguration.apiClient(
            serverURLString: PagePassRuntimeConfiguration.serverURLString
        )
        var draft = initialDraft
        var submission: ReadingSubmissionResponse

        if let submissionID = draft.serverSubmissionID {
            progressMessage = "Checking saved report"
            submission = try await client.childReadingSubmission(
                submissionID: submissionID,
                deviceCredential: credential
            )
            if submission.status == "pending" {
                try finish(submission)
                return
            }
            let expectedStatus = draft.transition == "resubmit"
                ? "changes_requested"
                : "draft"
            guard submission.status == expectedStatus else {
                throw ReadingSubmissionError.draftNotEditable
            }
        } else {
            progressMessage = "Creating report"
            submission = try await client.createReadingSubmission(
                bookTitle: draft.bookTitle,
                author: draft.author,
                supersedesSubmissionID: draft.supersedesSubmissionID,
                deviceCredential: credential
            )
            draft.serverSubmissionID = submission.id
            try recoveryStore.save(draft)
            recoverableDraft = draft
        }

        let localPageOrders = Set(draft.pages.map(\.pageOrder))
        for evidence in submission.evidence where
            !localPageOrders.contains(evidence.pageOrder) {
            progressMessage = "Removing old page \(evidence.pageOrder + 1)"
            try await client.removeReadingEvidence(
                submissionID: submission.id,
                evidenceID: evidence.id,
                deviceCredential: credential
            )
            submission = try await client.childReadingSubmission(
                submissionID: submission.id,
                deviceCredential: credential
            )
        }

        for page in draft.pages.sorted(by: { $0.pageOrder < $1.pageOrder }) {
            if let evidence = submission.evidence.first(where: {
                $0.pageOrder == page.pageOrder
            }) {
                if remoteEvidence(evidence, matches: page) {
                    continue
                }
                progressMessage = "Restarting page \(page.pageOrder + 1)"
                try await client.removeReadingEvidence(
                    submissionID: submission.id,
                    evidenceID: evidence.id,
                    deviceCredential: credential
                )
                submission = try await client.childReadingSubmission(
                    submissionID: submission.id,
                    deviceCredential: credential
                )
            }

            progressMessage = "Uploading page \(page.pageOrder + 1) of \(draft.pages.count)"
            let imageData = try recoveryStore.imageData(for: page)
            let intent = try await client.createReadingMediaUpload(
                submissionID: submission.id,
                contentType: "image/jpeg",
                byteSize: page.byteSize,
                sha256: page.sha256,
                pageOrder: page.pageOrder,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
            try await client.uploadReadingMedia(imageData, intent: intent)
            submission = try await client.completeReadingMediaUpload(
                submissionID: submission.id,
                uploadID: intent.uploadId,
                byteSize: page.byteSize,
                sha256: page.sha256,
                expectedVersion: intent.submissionVersion,
                deviceCredential: credential
            )
            submission = try await client.recordReadingOCR(
                submissionID: submission.id,
                evidenceID: intent.evidenceId,
                status: page.ocrStatus,
                rawText: page.rawText,
                languageCodes: page.languageCodes,
                ocrRevision: page.ocrRevision,
                visionRevision: page.visionRevision,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
        }

        let desiredCorrectedTranscript = draft.isTranscriptEdited &&
            draft.correctedTranscript != draft.rawTranscript
            ? draft.correctedTranscript
            : nil
        if draft.transition == "resubmit" &&
            submission.correctedOcrText != desiredCorrectedTranscript {
            progressMessage = "Saving transcript"
            submission = try await client.updateReadingTranscript(
                submissionID: submission.id,
                correctedOCRText: desiredCorrectedTranscript,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
        } else if draft.transition != "resubmit",
           let desiredCorrectedTranscript,
           submission.correctedOcrText != desiredCorrectedTranscript {
            progressMessage = "Saving transcript"
            submission = try await client.updateReadingTranscript(
                submissionID: submission.id,
                correctedOCRText: desiredCorrectedTranscript,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
        }

        progressMessage = "Sending to parent"
        if draft.transition == "resubmit" {
            submission = try await client.resubmitReadingSubmission(
                submissionID: submission.id,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
        } else {
            submission = try await client.submitReadingSubmission(
                submissionID: submission.id,
                expectedVersion: submission.version,
                deviceCredential: credential
            )
        }
        try finish(submission)
    }

    private func finish(_ submission: ReadingSubmissionResponse) throws {
        submittedReport = submission
        try recoveryStore.remove()
        recoverableDraft = nil
    }

    private func recoverablePage(
        _ page: HandwrittenReportPage,
        pageOrder: Int,
        imageData: Data
    ) throws -> RecoverableReadingPage {
        let ocr = try ocrPayload(for: page)
        let sha256 = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        return RecoverableReadingPage(
            pageOrder: pageOrder,
            imageFileName: "page-\(pageOrder).jpg",
            byteSize: imageData.count,
            sha256: sha256,
            ocrStatus: ocr.status,
            rawText: ocr.rawText,
            languageCodes: ocr.languageCodes,
            ocrRevision: ocr.ocrRevision,
            visionRevision: ocr.visionRevision
        )
    }

    private func remoteEvidence(
        _ evidence: ReadingEvidenceResponse,
        matches page: RecoverableReadingPage
    ) -> Bool {
        evidence.ocrStatus == page.ocrStatus &&
        evidence.ocrRevision == page.ocrRevision &&
        evidence.rawOcrText == (page.ocrStatus == "failed" ? nil : page.rawText) &&
        evidence.ocrLanguageCodes == page.languageCodes &&
        evidence.visionRevision == page.visionRevision
    }

    private func ocrPayload(for page: HandwrittenReportPage) throws -> OCRPayload {
        switch page.state {
        case let .completed(result):
            return OCRPayload(
                status: result.status.rawValue,
                rawText: result.rawText,
                languageCodes: result.configuredLanguageCodes,
                ocrRevision: max(1, page.ocrRevision),
                visionRevision: max(1, result.requestRevision)
            )
        case .failed:
            return OCRPayload(
                status: "failed",
                rawText: "",
                languageCodes: [],
                ocrRevision: max(1, page.ocrRevision),
                visionRevision: 1
            )
        case .pending, .processing:
            throw ReadingSubmissionError.ocrNotFinished
        }
    }

    private func normalizedJPEG(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.92) else {
            throw ReadingSubmissionError.invalidImage
        }
        return jpeg
    }

    private func normalizedOptionalText(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private struct OCRPayload {
    let status: String
    let rawText: String
    let languageCodes: [String]
    let ocrRevision: Int
    let visionRevision: Int
}

private enum ReadingSubmissionError: LocalizedError {
    case deviceNotPaired
    case invalidImage
    case ocrNotFinished
    case draftNotEditable

    var errorDescription: String? {
        switch self {
        case .deviceNotPaired:
            "Connect this device to a child profile before submitting."
        case .invalidImage:
            "One of the scanned pages could not be prepared for upload."
        case .ocrNotFinished:
            "Wait for every page to finish OCR before submitting."
        case .draftNotEditable:
            "This saved report is no longer editable. Refresh the Journal."
        }
    }
}

private extension PagePassAPIClient.ClientError {
    var statusCode: Int? {
        guard case let .server(statusCode, _) = self else { return nil }
        return statusCode
    }
}
