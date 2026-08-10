import Foundation

struct RecoverableReadingPage: Codable, Equatable, Sendable {
    let pageOrder: Int
    let imageFileName: String
    let byteSize: Int
    let sha256: String
    let ocrStatus: String
    let rawText: String
    let languageCodes: [String]
    let ocrRevision: Int
    let visionRevision: Int
}

struct RecoverableReadingDraft: Codable, Sendable {
    let schemaVersion: Int
    let localID: UUID
    var serverSubmissionID: String?
    let transition: String?
    let supersedesSubmissionID: String?
    let bookTitle: String
    let author: String?
    let rawTranscript: String
    let correctedTranscript: String
    let isTranscriptEdited: Bool
    let createdAt: Date
    let pages: [RecoverableReadingPage]
}

enum ReadingDraftRecoveryError: LocalizedError {
    case unavailable
    case existingDraft
    case unsupportedDraft
    case missingPage

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The report recovery folder is unavailable."
        case .existingDraft:
            "Finish or discard the unfinished report first."
        case .unsupportedDraft:
            "This saved report was created by an unsupported app version."
        case .missingPage:
            "A saved report page is missing. Scan the report again."
        }
    }
}

final class ReadingDraftRecoveryStore {
    private static let schemaVersion = 1
    private let fileManager: FileManager
    private let rootURL: URL?

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL
    }

    func create(
        bookTitle: String,
        author: String?,
        rawTranscript: String,
        correctedTranscript: String,
        isTranscriptEdited: Bool,
        serverSubmissionID: String? = nil,
        transition: String? = nil,
        supersedesSubmissionID: String? = nil,
        pages: [(data: Data, ocr: RecoverableReadingPage)]
    ) throws -> RecoverableReadingDraft {
        if try load() != nil {
            throw ReadingDraftRecoveryError.existingDraft
        }

        let directory = try recoveryDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)

        for page in pages {
            try page.data.write(
                to: directory.appending(path: page.ocr.imageFileName),
                options: [.atomic, .completeFileProtection]
            )
        }

        let draft = RecoverableReadingDraft(
            schemaVersion: Self.schemaVersion,
            localID: UUID(),
            serverSubmissionID: serverSubmissionID,
            transition: transition,
            supersedesSubmissionID: supersedesSubmissionID,
            bookTitle: bookTitle,
            author: author,
            rawTranscript: rawTranscript,
            correctedTranscript: correctedTranscript,
            isTranscriptEdited: isTranscriptEdited,
            createdAt: Date(),
            pages: pages.map(\.ocr)
        )
        try save(draft)
        return draft
    }

    func load() throws -> RecoverableReadingDraft? {
        let manifest = try manifestURL()
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        let draft = try JSONDecoder().decode(
            RecoverableReadingDraft.self,
            from: Data(contentsOf: manifest)
        )
        guard draft.schemaVersion == Self.schemaVersion else {
            throw ReadingDraftRecoveryError.unsupportedDraft
        }
        return draft
    }

    func save(_ draft: RecoverableReadingDraft) throws {
        let directory = try recoveryDirectory()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(draft).write(
            to: try manifestURL(),
            options: [.atomic, .completeFileProtection]
        )
    }

    func imageData(for page: RecoverableReadingPage) throws -> Data {
        let url = try recoveryDirectory().appending(path: page.imageFileName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ReadingDraftRecoveryError.missingPage
        }
        return try Data(contentsOf: url)
    }

    func remove() throws {
        let directory = try recoveryDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func remove(ifServerSubmissionIDMatches submissionID: String) throws {
        guard try load()?.serverSubmissionID == submissionID else { return }
        try remove()
    }

    private func recoveryDirectory() throws -> URL {
        if let rootURL {
            return rootURL.appending(path: "ActiveReadingDraft", directoryHint: .isDirectory)
        }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ReadingDraftRecoveryError.unavailable
        }
        return support
            .appending(path: "PagePass", directoryHint: .isDirectory)
            .appending(path: "ActiveReadingDraft", directoryHint: .isDirectory)
    }

    private func manifestURL() throws -> URL {
        try recoveryDirectory().appending(path: "manifest.json")
    }

    private func excludeFromBackup(_ directory: URL) throws {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
