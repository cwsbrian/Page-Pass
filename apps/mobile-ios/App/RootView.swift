import SwiftUI

struct RootView: View {
    @AppStorage("pagepass.installationRole") private var storedRole = ""

    var body: some View {
        Group {
            switch InstallationRole(rawValue: storedRole) {
            case .parent:
                ParentGateView()
            case .child:
                ChildHomeView()
            case nil:
                InstallationRoleView { role in
                    storedRole = role.rawValue
                }
            }
        }
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
                    Label("Parent", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button {
                    selectRole(.child)
                } label: {
                    Label("Child", systemImage: "person.crop.circle")
                }
            }
            .navigationTitle("PagePass")
        }
    }
}
