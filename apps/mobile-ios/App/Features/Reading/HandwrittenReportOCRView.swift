import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct ReadingRevisionRequest: Equatable {
    let submissionID: String
    let bookTitle: String
    let author: String
}

struct HandwrittenReportOCRView: View {
    @Binding private var revisionRequest: ReadingRevisionRequest?
    @State private var store = HandwrittenReportOCRStore()
    @State private var submissionStore = ReadingSubmissionStore()
    @State private var showingDocumentScanner = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var bookTitle = ""
    @State private var author = ""
    @State private var supersedesSubmissionID: String?
    @State private var showingDiscardConfirmation = false
    @State private var autosaveTask: Task<Void, Never>?
    private let captureDraftStore = ReadingCaptureDraftStore()

    init(
        revisionRequest: Binding<ReadingRevisionRequest?> = .constant(nil)
    ) {
        _revisionRequest = revisionRequest
    }

    var body: some View {
        List {
            captureSection

            if submissionStore.hasRecoverableDraft {
                recoverySection
            } else if submissionStore.isSubmitted && store.pages.isEmpty {
                Section {
                    Label("Pending Parent Review", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if !store.pages.isEmpty {
                bookSection
                summarySection
                pageSections
                transcriptSection
                submissionSection
            }

            if let message = store.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let message = submissionStore.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Reading Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.pages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        store.clear()
                        submissionStore.clear()
                        selectedPhotos = []
                        bookTitle = ""
                        author = ""
                        supersedesSubmissionID = nil
                        try? captureDraftStore.remove()
                        applyPendingRevisionRequest()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear reading report")
                    .accessibilityHint("Removes the scanned pages and OCR text")
                    .help("Clear OCR run")
                    .disabled(store.isProcessing || submissionStore.isSubmitting)
                }
            }
        }
        .fullScreenCover(isPresented: $showingDocumentScanner) {
            DocumentScannerView { pages in
                showingDocumentScanner = false
                Task { await store.recognizeNewPages(pages) }
            } onCancel: {
                showingDocumentScanner = false
            } onFailure: { message in
                showingDocumentScanner = false
                store.reportCaptureError(message)
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadSelectedPhotos(items) }
        }
        .task {
            restoreCaptureDraft()
            applyPendingRevisionRequest()
        }
        .onChange(of: revisionRequest) { _, _ in
            applyPendingRevisionRequest()
        }
        .onChange(of: bookTitle) { _, _ in scheduleAutosave() }
        .onChange(of: author) { _, _ in scheduleAutosave() }
        .onChange(of: store.pages) { _, _ in scheduleAutosave() }
        .onChange(of: store.correctedTranscript) { _, _ in scheduleAutosave() }
        .onChange(of: submissionStore.hasRecoverableDraft) { _, hasDraft in
            if hasDraft { try? captureDraftStore.remove() }
        }
        .onChange(of: submissionStore.isSubmitted) { _, submitted in
            if submitted { try? captureDraftStore.remove() }
        }
        .confirmationDialog(
            "Discard this unfinished report?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Report", role: .destructive) {
                Task { await submissionStore.discardRecoverableDraft() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved pages and server draft will be removed.")
        }
    }

    private var bookSection: some View {
        Section("Book") {
            TextField("Title", text: $bookTitle)
                .textInputAutocapitalization(.words)
            TextField("Author", text: $author)
                .textInputAutocapitalization(.words)
        }
        .disabled(submissionStore.isSubmitting || submissionStore.isSubmitted)
    }

    private var captureSection: some View {
        Section("Capture") {
            Button {
                showingDocumentScanner = true
            } label: {
                Label("Scan Handwritten Report", systemImage: "doc.viewfinder")
            }
            .disabled(
                !VNDocumentCameraViewController.isSupported ||
                store.isProcessing ||
                submissionStore.isSubmitting ||
                submissionStore.isSubmitted ||
                submissionStore.hasRecoverableDraft
            )

            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                Label("Choose Existing Photos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(
                store.isProcessing ||
                submissionStore.isSubmitting ||
                submissionStore.isSubmitted ||
                submissionStore.hasRecoverableDraft
            )

            LabeledContent(
                "Document Camera",
                value: VNDocumentCameraViewController.isSupported ? "Available" : "Unavailable"
            )
        }
    }

    private var recoverySection: some View {
        Section("Unfinished Report") {
            if let draft = submissionStore.recoverableDraft {
                LabeledContent("Book", value: draft.bookTitle)
                LabeledContent("Pages", value: "\(draft.pages.count)")
            }

            Button {
                Task { await submissionStore.resumeRecoverableDraft() }
            } label: {
                Label("Retry Upload", systemImage: "arrow.clockwise")
            }
            .disabled(submissionStore.isSubmitting)

            Button(role: .destructive) {
                showingDiscardConfirmation = true
            } label: {
                Label("Discard Report", systemImage: "trash")
            }
            .disabled(submissionStore.isSubmitting)

            if let progress = submissionStore.progressMessage {
                HStack {
                    ProgressView()
                    Text(progress)
                }
            }
        }
    }

    private var summarySection: some View {
        Section("Run Summary") {
            LabeledContent("Pages", value: "\(store.pages.count)")
            LabeledContent("Completed", value: "\(store.completedResults.count)")
            LabeledContent("Korean", value: supportDescription(store.koreanRecognitionSupported))
            LabeledContent("English", value: supportDescription(store.englishRecognitionSupported))
            LabeledContent("OCR Time", value: "\(store.totalElapsedMilliseconds) ms")

            if store.isProcessing {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var pageSections: some View {
        ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
            Section("Page \(index + 1)") {
                if let image = UIImage(data: page.imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Scanned report page \(index + 1)")
                }

                pageResult(page)

                Button {
                    Task { await store.retryPage(id: page.id) }
                } label: {
                    Label("Retry OCR", systemImage: "arrow.clockwise")
                }
                .disabled(
                    store.isProcessing ||
                    submissionStore.isSubmitting ||
                    submissionStore.isSubmitted ||
                    submissionStore.hasRecoverableDraft
                )
            }
        }
    }

    @ViewBuilder
    private func pageResult(_ page: HandwrittenReportPage) -> some View {
        switch page.state {
        case .pending:
            Label("Pending", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .processing:
            HStack {
                ProgressView()
                Text("Recognizing")
            }
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case let .completed(result):
            LabeledContent("Status", value: result.status.displayName)
            LabeledContent("OCR Revision", value: "\(page.ocrRevision)")
            LabeledContent("Vision Revision", value: "\(result.requestRevision)")
            LabeledContent("Languages", value: result.configuredLanguageCodes.joined(separator: ", "))
            LabeledContent("Lines", value: "\(result.lines.count)")
            LabeledContent("Characters", value: "\(result.characterCount)")
            LabeledContent("Time", value: "\(result.elapsedMilliseconds) ms")
            LabeledContent("Confidence", value: confidenceDescription(result.averageConfidence))

            if result.rawText.isEmpty {
                Text("No text recognized")
                    .foregroundStyle(.secondary)
            } else {
                Text(result.rawText)
                    .textSelection(.enabled)
            }
        }
    }

    private var transcriptSection: some View {
        Section("Transcript") {
            TextEditor(
                text: Binding(
                    get: { store.correctedTranscript },
                    set: { store.updateCorrectedTranscript($0) }
                )
            )
            .frame(minHeight: 180)
            .disabled(
                store.isProcessing ||
                submissionStore.isSubmitting ||
                submissionStore.isSubmitted
            )

            LabeledContent("Edited", value: store.isTranscriptEdited ? "Yes" : "No")

            Button {
                store.resetCorrection()
            } label: {
                Label("Restore Raw OCR", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.isTranscriptEdited)
        }
    }

    private var submissionSection: some View {
        Section("Review") {
            if submissionStore.isSubmitted {
                Label("Pending Parent Review", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task {
                        await submissionStore.submit(
                            bookTitle: bookTitle,
                            author: author,
                            pages: store.pages,
                            rawTranscript: store.rawTranscript,
                            correctedTranscript: store.correctedTranscript,
                            isTranscriptEdited: store.isTranscriptEdited,
                            supersedesSubmissionID: supersedesSubmissionID
                        )
                    }
                } label: {
                    Label("Submit for Review", systemImage: "paperplane.fill")
                }
                .disabled(
                    store.isProcessing ||
                    submissionStore.isSubmitting ||
                    submissionStore.hasRecoverableDraft ||
                    bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let progress = submissionStore.progressMessage {
                HStack {
                    ProgressView()
                    Text(progress)
                }
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var pages: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            pages.append(data)
        }
        guard !pages.isEmpty else {
            store.reportCaptureError("The selected photos could not be loaded.")
            return
        }
        await store.recognizeNewPages(pages)
    }

    private func supportDescription(_ supported: Bool?) -> String {
        switch supported {
        case true: "Supported"
        case false: "Unavailable"
        case nil: "Pending"
        }
    }

    private func confidenceDescription(_ confidence: Float?) -> String {
        guard let confidence else { return "-" }
        return confidence.formatted(.percent.precision(.fractionLength(1)))
    }

    private func restoreCaptureDraft() {
        guard !submissionStore.hasRecoverableDraft, store.pages.isEmpty,
              let saved = try? captureDraftStore.load() else { return }
        bookTitle = saved.0.bookTitle
        author = saved.0.author
        supersedesSubmissionID = saved.0.supersedesSubmissionID
        store.restore(
            pages: saved.1,
            correctedTranscript: saved.0.correctedTranscript,
            isTranscriptEdited: saved.0.isTranscriptEdited
        )
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  !submissionStore.hasRecoverableDraft,
                  !submissionStore.isSubmitted else { return }
            try? captureDraftStore.save(
                bookTitle: bookTitle,
                author: author,
                supersedesSubmissionID: supersedesSubmissionID,
                correctedTranscript: store.correctedTranscript,
                isTranscriptEdited: store.isTranscriptEdited,
                pages: store.pages
            )
        }
    }

    private func applyPendingRevisionRequest() {
        guard let request = revisionRequest else { return }
        if submissionStore.isSubmitted {
            submissionStore.clear()
        }
        guard !submissionStore.hasRecoverableDraft, store.pages.isEmpty else {
            store.reportCaptureError(
                "Finish or discard the unfinished report before revising another report."
            )
            return
        }
        bookTitle = request.bookTitle
        author = request.author
        supersedesSubmissionID = request.submissionID
        revisionRequest = nil
    }
}

private extension HandwritingOCRStatus {
    var displayName: String {
        switch self {
        case .succeeded: String(localized: "Succeeded")
        case .lowConfidence: String(localized: "Low Confidence")
        case .failed: String(localized: "Failed")
        }
    }
}
