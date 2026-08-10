import Foundation
import FamilyControls
import PagePassCore
import Testing
import UIKit

@testable import PagePass

@Test("Earned Time activity names round trip their session ID")
func activityNameRoundTrip() throws {
    let id = UUID()
    let activity = PagePassScreenTime.activityName(for: id)

    #expect(PagePassScreenTime.sessionID(from: activity) == id)
    #expect(PagePassScreenTime.isEarnedTimeActivity(activity))
}

@Test("A configured policy still requires an Earned Time application")
func policyReadinessRequiresAnApplication() {
    let policy = ManagedAppPolicySnapshot(
        isConfigured: true,
        earnedTime: FamilyActivitySelection(includeEntireCategory: false)
    )

    #expect(!policy.isReadyForEarnedTime)
}

@Test("Standard Screen Time approval allows PagePass control")
func standardAuthorizationAllowsControl() {
    #expect(AuthorizationStatus.approved.allowsPagePassControl)
    #expect(!AuthorizationStatus.denied.allowsPagePassControl)
    #expect(!AuthorizationStatus.notDetermined.allowsPagePassControl)
}

@Test("Stored policies from before server versioning decode as version zero")
func legacyPolicySnapshotDecodes() throws {
    struct LegacySnapshot: Codable {
        let isConfigured: Bool
        let blocked: FamilyActivitySelection
        let earnedTime: FamilyActivitySelection
        let alwaysAllowed: FamilyActivitySelection
    }

    let data = try JSONEncoder().encode(
        LegacySnapshot(
            isConfigured: true,
            blocked: FamilyActivitySelection(includeEntireCategory: false),
            earnedTime: FamilyActivitySelection(includeEntireCategory: false),
            alwaysAllowed: FamilyActivitySelection(includeEntireCategory: false)
        )
    )
    let decoded = try JSONDecoder().decode(
        ManagedAppPolicySnapshot.self,
        from: data
    )

    #expect(decoded.isConfigured)
    #expect(decoded.policyVersion == 0)
}

@Test("Applied policy markers are scoped to the server, child, and installation")
func appliedPolicyMarkerIdentityScope() {
    let marker = ManagedAppPolicyApplicationMarker(
        serverInstanceID: "server-a",
        childProfileID: "child-a",
        installationID: "installation-a",
        policyVersion: 1
    )

    #expect(marker != ManagedAppPolicyApplicationMarker(
        serverInstanceID: "server-b",
        childProfileID: marker.childProfileID,
        installationID: marker.installationID,
        policyVersion: marker.policyVersion
    ))
    #expect(marker != ManagedAppPolicyApplicationMarker(
        serverInstanceID: marker.serverInstanceID,
        childProfileID: "child-b",
        installationID: marker.installationID,
        policyVersion: marker.policyVersion
    ))
    #expect(marker != ManagedAppPolicyApplicationMarker(
        serverInstanceID: marker.serverInstanceID,
        childProfileID: marker.childProfileID,
        installationID: "installation-b",
        policyVersion: marker.policyVersion
    ))
}

@Test("Earned Time state and pending settlement survive independent store instances")
func appGroupSessionStateSurvivesRelaunch() throws {
    let suiteName = "PagePassTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let lockURL = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).lock")
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let firstProcess = AppGroupSessionStore(defaults: defaults, lockURL: lockURL)
    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_000)

    var state = EarnedTimeState(balanceSeconds: 1_800)
    try EarnedTimeReducer.reduce(
        .prepareSession(id: sessionID, durationSeconds: 900, startedAt: startedAt),
        state: &state
    )
    try EarnedTimeReducer.reduce(
        .scheduleRegistered(id: sessionID, registeredAt: startedAt),
        state: &state
    )
    try firstProcess.save(state)

    let relaunchedProcess = AppGroupSessionStore(defaults: defaults, lockURL: lockURL)
    #expect(try relaunchedProcess.load() == state)
    let stopped = try relaunchedProcess.mutate {
        try EarnedTimeReducer.reduce(
            .beginEnding(
                id: sessionID,
                endedAt: startedAt.addingTimeInterval(90),
                reason: .manualStop
            ),
            state: &$0
        )
        try EarnedTimeReducer.reduce(.finishEnding(id: sessionID), state: &$0)
    }
    #expect(stopped.pendingSettlements.count == 1)
    #expect(stopped.balanceSeconds == 1_710)

    let offlineRelaunch = AppGroupSessionStore(defaults: defaults, lockURL: lockURL)
    let pending = try offlineRelaunch.load()
    #expect(pending.pendingSettlements.first?.consumedSeconds == 90)
    let synced = try offlineRelaunch.mutate {
        try EarnedTimeReducer.reduce(.settlementSynced(id: sessionID), state: &$0)
    }
    #expect(synced.pendingSettlements.isEmpty)
    #expect(synced.session?.phase == .settled)
}

@Test("OCR quality fails when no text is recognized")
func ocrQualityFailsWithoutText() {
    #expect(HandwritingOCRQuality.status(for: []) == .failed)
}

@Test("OCR quality reports low confidence below the proof threshold")
func ocrQualityReportsLowConfidence() {
    let lines = [
        HandwritingOCRLine(id: 0, text: "A difficult line", confidence: 0.2),
        HandwritingOCRLine(id: 1, text: "Another line", confidence: 0.4),
    ]

    #expect(HandwritingOCRQuality.status(for: lines) == .lowConfidence)
}

@Test("OCR transcript preserves page order and skips empty pages")
func ocrTranscriptPreservesPageOrder() {
    func result(_ text: String) -> HandwritingOCRResult {
        let lines = text.isEmpty
            ? []
            : [HandwritingOCRLine(id: 0, text: text, confidence: 0.9)]
        return HandwritingOCRResult(
            status: HandwritingOCRQuality.status(for: lines),
            lines: lines,
            supportedLanguageCodes: ["ko-KR", "en-US"],
            configuredLanguageCodes: ["ko-KR", "en-US"],
            requestRevision: 3,
            elapsedMilliseconds: 100
        )
    }

    #expect(
        HandwritingOCRQuality.combinedTranscript([
            result("first page"),
            result(""),
            result("third page"),
        ]) == "first page\n\nthird page"
    )
}

@Test("Reading upload recovery persists pages and server progress")
func readingUploadRecoveryRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReadingDraftRecoveryStore(rootURL: root)
    let imageData = Data("private report page".utf8)
    let page = RecoverableReadingPage(
        pageOrder: 0,
        imageFileName: "page-0.jpg",
        byteSize: imageData.count,
        sha256: String(repeating: "a", count: 64),
        ocrStatus: "succeeded",
        rawText: "A page",
        languageCodes: ["en-US"],
        ocrRevision: 1,
        visionRevision: 3
    )

    var draft = try store.create(
        bookTitle: "A Book",
        author: "An Author",
        rawTranscript: "A page",
        correctedTranscript: "A page",
        isTranscriptEdited: false,
        supersedesSubmissionID: "rejected-submission",
        pages: [(data: imageData, ocr: page)]
    )
    draft.serverSubmissionID = "submission-1"
    try store.save(draft)

    let loaded = try store.load()
    let restored = try #require(loaded)
    #expect(restored.serverSubmissionID == "submission-1")
    #expect(restored.supersedesSubmissionID == "rejected-submission")
    #expect(restored.pages == [page])
    #expect(try store.imageData(for: page) == imageData)

    try store.remove(ifServerSubmissionIDMatches: "another-submission")
    #expect(try store.load() != nil)

    try store.remove(ifServerSubmissionIDMatches: "submission-1")
    let removed = try store.load()
    #expect(removed == nil)
}

@Test("Reading capture autosave restores pages and OCR without rerunning Vision")
func readingCaptureDraftRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReadingCaptureDraftStore(rootURL: root)
    let result = HandwritingOCRResult(
        status: .succeeded,
        lines: [HandwritingOCRLine(id: 0, text: "Saved words", confidence: 0.9)],
        supportedLanguageCodes: ["en-US"],
        configuredLanguageCodes: ["en-US"],
        requestRevision: 3,
        elapsedMilliseconds: 42
    )
    let page = HandwrittenReportPage(
        id: UUID(),
        imageData: Data("page image".utf8),
        ocrRevision: 1,
        state: .completed(result)
    )

    try store.save(
        bookTitle: "Saved Book",
        author: "Saved Author",
        supersedesSubmissionID: "rejected-submission",
        correctedTranscript: "Edited words",
        isTranscriptEdited: true,
        pages: [page]
    )
    let saved = try store.load()
    let loaded = try #require(saved)
    #expect(loaded.0.bookTitle == "Saved Book")
    #expect(loaded.0.supersedesSubmissionID == "rejected-submission")
    #expect(loaded.0.correctedTranscript == "Edited words")
    #expect(loaded.1 == [page])

    try store.remove()
    let removed = try store.load()
    #expect(removed == nil)
}

@Test("Vision OCR recognizes a generated proof image")
func visionOCRRecognizesGeneratedProofImage() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600))
    let image = renderer.image { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 96, weight: .regular),
            .foregroundColor: UIColor.black,
        ]
        NSString(string: "PagePass OCR proof").draw(
            at: CGPoint(x: 80, y: 220),
            withAttributes: attributes
        )
    }
    let imageData = try #require(image.jpegData(compressionQuality: 0.95))

    let result = try await HandwritingTextRecognizer().recognize(imageData: imageData)

    #expect(result.status != .failed)
    #expect(result.rawText.localizedCaseInsensitiveContains("PagePass"))
    #expect(result.configuredLanguageCodes.contains { $0.hasPrefix("en") })
    #expect(result.elapsedMilliseconds >= 0)
}
