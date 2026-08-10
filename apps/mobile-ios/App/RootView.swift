import SwiftUI

struct RootView: View {
    @AppStorage("pagepass.installationRole") private var storedRole = ""

    var body: some View {
        Group {
            switch effectiveRole {
            case .parent:
                ParentGateView()
            case .child:
                ChildTabView {
                    storedRole = ""
                }
            case nil:
                InstallationRoleView { role in
                    storedRole = role.rawValue
                }
            }
        }
        .tint(PagePassTheme.tint)
    }

    private var effectiveRole: InstallationRole? {
#if DEBUG
        if let testRole = ProcessInfo.processInfo.environment[
            "PAGEPASS_UI_TEST_ROLE"
        ] {
            return InstallationRole(rawValue: testRole)
        }
#endif
        return InstallationRole(rawValue: storedRole)
    }
}

private enum InstallationRole: String {
    case parent
    case child
}

private struct InstallationRoleView: View {
    let selectRole: (InstallationRole) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectRole(.parent)
                } label: {
                    PagePassActionLabel(
                        title: "Parent",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                Button {
                    selectRole(.child)
                } label: {
                    PagePassActionLabel(
                        title: "Child",
                        systemImage: "person.crop.circle"
                    )
                }
            }
            .navigationTitle("PagePass")
        }
    }
}
