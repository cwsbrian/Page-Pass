import Observation
import UIKit
@preconcurrency import UserNotifications

@MainActor
@Observable
final class PagePassPushCoordinator {
    static let shared = PagePassPushCoordinator()

    private(set) var deviceToken: String?
    private(set) var eventRevision = 0
    private(set) var eventType: String?
    private(set) var childProfileID: String?
    private(set) var readingSubmissionID: String?

    func requestRegistration() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
    }

    func receivedEvent(
        type: String,
        childProfileID: String?,
        readingSubmissionID: String?,
        opensDeepLink: Bool
    ) {
        eventType = type
        self.childProfileID = childProfileID
        self.readingSubmissionID = opensDeepLink ? readingSubmissionID : nil
        eventRevision &+= 1
    }

    func clearReadingDeepLink() {
        readingSubmissionID = nil
    }
}

private final class PagePassNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate, @unchecked Sendable {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let event = pagePassEvent(
            userInfo: notification.request.content.userInfo
        )
        if let event {
            await PagePassPushCoordinator.shared.receivedEvent(
                type: event.type,
                childProfileID: event.childProfileID,
                readingSubmissionID: event.readingSubmissionID,
                opensDeepLink: false
            )
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let event = pagePassEvent(
            userInfo: response.notification.request.content.userInfo
        )
        if let event {
            await PagePassPushCoordinator.shared.receivedEvent(
                type: event.type,
                childProfileID: event.childProfileID,
                readingSubmissionID: event.readingSubmissionID,
                opensDeepLink: true
            )
        }
    }

    private func pagePassEvent(
        userInfo: [AnyHashable: Any]
    ) -> (
        type: String,
        childProfileID: String?,
        readingSubmissionID: String?
    )? {
        guard let pagePass = userInfo["pagePass"] as? [String: Any],
              let type = pagePass["type"] as? String,
              type == "app_request_created" ||
                type == "reading_submission_submitted" ||
                type == "reading_submission_reviewed" ||
                type == "device_attention_required" ||
                type == "earned_time_session_ended" else {
            return nil
        }
        return (
            type,
            pagePass["childProfileId"] as? String,
            pagePass["submissionId"] as? String
        )
    }
}

@MainActor
final class PagePassAppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = PagePassNotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PagePassPushCoordinator.shared.received(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
#if DEBUG
        print("Remote notification registration failed: \(error.localizedDescription)")
#endif
    }
}
