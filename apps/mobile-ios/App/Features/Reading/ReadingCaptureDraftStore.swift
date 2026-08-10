import Foundation

struct ReadingCaptureDraftPage: Codable, Sendable {
    let id: UUID
    let imageFileName: String
    let ocrRevision: Int
    let result: HandwritingOCRResult?
    let failureMessage: String?
}

struct ReadingCaptureDraft: Codable, Sendable {
    let bookTitle: String
    let author: String
    let supersedesSubmissionID: String?
    let correctedTranscript: String
    let isTranscriptEdited: Bool
    let pages: [ReadingCaptureDraftPage]
}

final class ReadingCaptureDraftStore {
    private let fileManager: FileManager
    private let rootURL: URL?

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL
    }

    func save(
        bookTitle: String,
        author: String,
        supersedesSubmissionID: String? = nil,
        correctedTranscript: String,
        isTranscriptEdited: Bool,
        pages: [HandwrittenReportPage]
    ) throws {
        guard !pages.isEmpty else {
            try remove()
            return
        }
        let directory = try draftDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)
        var storedPages: [ReadingCaptureDraftPage] = []
        for (index, page) in pages.enumerated() {
            let fileName = "page-\(index)-\(page.id.uuidString.lowercased()).image"
            try page.imageData.write(
                to: directory.appending(path: fileName),
                options: [.atomic, .completeFileProtection]
            )
            let result: HandwritingOCRResult?
            let failureMessage: String?
            switch page.state {
            case let .completed(value):
                result = value
                failureMessage = nil
            case let .failed(message):
                result = nil
                failureMessage = message
            case .pending, .processing:
                result = nil
                failureMessage = nil
            }
            storedPages.append(ReadingCaptureDraftPage(
                id: page.id,
                imageFileName: fileName,
                ocrRevision: page.ocrRevision,
                result: result,
                failureMessage: failureMessage
            ))
        }
        let keep = Set(storedPages.map(\.imageFileName)).union(["manifest.json"])
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where !keep.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        let draft = ReadingCaptureDraft(
            bookTitle: bookTitle,
            author: author,
            supersedesSubmissionID: supersedesSubmissionID,
            correctedTranscript: correctedTranscript,
            isTranscriptEdited: isTranscriptEdited,
            pages: storedPages
        )
        try JSONEncoder().encode(draft).write(
            to: directory.appending(path: "manifest.json"),
            options: [.atomic, .completeFileProtection]
        )
    }

    func load() throws -> (ReadingCaptureDraft, [HandwrittenReportPage])? {
        let directory = try draftDirectory()
        let manifest = directory.appending(path: "manifest.json")
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        let draft = try JSONDecoder().decode(
            ReadingCaptureDraft.self,
            from: Data(contentsOf: manifest)
        )
        let pages = try draft.pages.map { page in
            let data = try Data(contentsOf: directory.appending(path: page.imageFileName))
            let state: HandwrittenReportPageState
            if let result = page.result {
                state = .completed(result)
            } else if let message = page.failureMessage {
                state = .failed(message)
            } else {
                state = .pending
            }
            return HandwrittenReportPage(
                id: page.id,
                imageData: data,
                ocrRevision: page.ocrRevision,
                state: state
            )
        }
        return (draft, pages)
    }

    func remove() throws {
        let directory = try draftDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func draftDirectory() throws -> URL {
        if let rootURL {
            return rootURL.appending(path: "ReadingCaptureDraft", directoryHint: .isDirectory)
        }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ReadingDraftRecoveryError.unavailable
        }
        return support
            .appending(path: "PagePass", directoryHint: .isDirectory)
            .appending(path: "ReadingCaptureDraft", directoryHint: .isDirectory)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
