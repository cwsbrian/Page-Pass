import Foundation

struct SpikeEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let activityName: String?
    let eventName: String?
    let runID: String?
    let timestamp: Date
    let source: String
    let creditBefore: Int
    let creditAfter: Int
    let selectedApplicationTokenCount: Int
    let detail: String

    init(
        id: UUID = UUID(),
        name: String,
        activityName: String? = nil,
        eventName: String? = nil,
        runID: String? = nil,
        timestamp: Date = Date(),
        source: String,
        creditBefore: Int,
        creditAfter: Int,
        selectedApplicationTokenCount: Int,
        detail: String = ""
    ) {
        self.id = id
        self.name = name
        self.activityName = activityName
        self.eventName = eventName
        self.runID = runID
        self.timestamp = timestamp
        self.source = source
        self.creditBefore = creditBefore
        self.creditAfter = creditAfter
        self.selectedApplicationTokenCount = selectedApplicationTokenCount
        self.detail = detail
    }
}
