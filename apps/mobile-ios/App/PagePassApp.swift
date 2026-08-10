import SwiftUI

@main
struct PagePassApp: App {
    @UIApplicationDelegateAdaptor(PagePassAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
