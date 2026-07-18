import DeviceActivity
import FamilyControls
import Foundation

enum PagePassScreenTime {
    static let appGroupID = "group.com.pagepass.app"
    static let managedStoreName = "pagepass.managed-apps"
    static let activityPrefix = "pagepass.earned-time."

    static func activityName(for sessionID: UUID) -> DeviceActivityName {
        DeviceActivityName(activityPrefix + sessionID.uuidString.lowercased())
    }

    static func sessionID(from activity: DeviceActivityName) -> UUID? {
        guard activity.rawValue.hasPrefix(activityPrefix) else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(activityPrefix.count)))
    }

    static func isEarnedTimeActivity(_ activity: DeviceActivityName) -> Bool {
        activity.rawValue.hasPrefix(activityPrefix)
    }
}

extension AuthorizationStatus {
    var allowsPagePassControl: Bool {
        if self == .approved {
            return true
        }
        if #available(iOS 26.4, *), self == .approvedWithDataAccess {
            return true
        }
        return false
    }
}
