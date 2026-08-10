import DeviceActivity
import FamilyControls
import Foundation

enum PagePassScreenTime {
    static let appGroupID = "group.com.pagepass.app"
    static let managedStoreName = "pagepass.managed-apps"
    static let activityPrefix = "pagepass.earned-time."
    static let installationIDKey = "pagepass.installationID"
    static let safariBundleID = "com.apple.mobilesafari"

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

    static func recordMonitorDiagnostic(
        _ event: String,
        activity: DeviceActivityName,
        detail: String? = nil,
        at date: Date = Date()
    ) {
#if DEBUG
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let value = [
            String(date.timeIntervalSince1970),
            activity.rawValue,
            detail ?? ""
        ].joined(separator: "|")
        defaults.set(value, forKey: "deviceActivityDiagnostic.\(event)")
#endif
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
