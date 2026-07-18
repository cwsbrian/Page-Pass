import AuthenticationServices
import SwiftUI

struct ParentGateView: View {
    @State private var store = ParentAuthStore()

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView()
            case .signedOut:
                NavigationStack {
                    List {
                        Section {
                            SignInWithAppleButton(.continue) { request in
                                store.configure(request)
                            } onCompletion: { result in
                                Task { await store.complete(result) }
                            }
                            .frame(height: 48)
                            .disabled(store.challenge == nil || store.isWorking)

                            if store.challenge == nil {
                                Button {
                                    Task { await store.load() }
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .disabled(store.isWorking)
                            }
                        }

                        if let message = store.errorMessage {
                            Section {
                                Text(message)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .navigationTitle("Parent Sign In")
                }
            case .authenticated:
                if PagePassRuntimeConfiguration.parentToken == nil {
                    ParentHomeView {
                        await store.signOut()
                    }
                } else {
                    ParentHomeView()
                }
            }
        }
        .task { await store.load() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            )
        ) { _ in
            Task { await store.handleCredentialRevocation() }
        }
    }
}
