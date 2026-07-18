import Foundation
import FamilyControls
import Testing

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
