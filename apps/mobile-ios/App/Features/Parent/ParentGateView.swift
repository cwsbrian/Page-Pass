import SwiftUI

struct ParentGateView: View {
    private enum AuthMode: CaseIterable, Identifiable {
        case signIn
        case signUp

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .signIn: "Sign In"
            case .signUp: "Create Account"
            }
        }
    }

    @State private var store = ParentAuthStore()
    @State private var mode = AuthMode.signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showingPasswordRequest = false
    @State private var resetPassword = ""

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView()
            case .signedOut:
                authView
            case .authenticated:
                if PagePassRuntimeConfiguration.parentToken == nil {
                    ParentTabView(
                        parent: store.parent,
                        onSignOut: { await store.signOut() },
                        onDeleteAccount: { await store.deleteAccount() }
                    )
                } else {
                    ParentTabView()
                }
            }
        }
        .task { await store.load() }
        .onOpenURL { store.handle(url: $0) }
        .sheet(isPresented: $showingPasswordRequest) {
            passwordRequestView
        }
        .sheet(
            isPresented: Binding(
                get: { store.passwordResetToken != nil },
                set: { if !$0 { store.clearPasswordReset() } }
            )
        ) {
            passwordResetView
        }
    }

    private var authView: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Account", selection: $mode) {
                        ForEach(AuthMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if mode == .signUp {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        Label(mode.title, systemImage: mode == .signIn
                            ? "person.crop.circle.badge.checkmark"
                            : "person.badge.plus")
                    }
                    .disabled(store.isWorking)

                    if mode == .signIn {
                        Button("Forgot Password?") {
                            showingPasswordRequest = true
                        }
                        Button("Resend Verification Email") {
                            Task { await store.resendVerification(email: email) }
                        }
                        .disabled(store.isWorking)
                    }
                }

                Section("Legal") {
                    NavigationLink("Privacy Policy") {
                        PagePassLegalDocumentView(document: .privacy)
                    }
                    NavigationLink("Terms of Use") {
                        PagePassLegalDocumentView(document: .terms)
                    }
                }

                messageSections
            }
            .navigationTitle("Parent Account")
        }
    }

    private var passwordRequestView: some View {
        NavigationStack {
            Form {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                messageSections
            }
            .navigationTitle("Reset Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPasswordRequest = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            if await store.requestPasswordReset(email: email) {
                                showingPasswordRequest = false
                            }
                        }
                    }
                    .disabled(store.isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var passwordResetView: some View {
        NavigationStack {
            Form {
                SecureField("New Password", text: $resetPassword)
                    .textContentType(.newPassword)
                messageSections
            }
            .navigationTitle("New Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.clearPasswordReset() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") {
                        Task {
                            if await store.resetPassword(resetPassword) {
                                resetPassword = ""
                            }
                        }
                    }
                    .disabled(store.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(store.isWorking)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.noticeMessage {
            Section {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        if let message = store.errorMessage {
            Section {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    private func submit() async {
        switch mode {
        case .signIn:
            if await store.signIn(email: email, password: password) {
                password = ""
            }
        case .signUp:
            if await store.signUp(name: name, email: email, password: password) {
                password = ""
                mode = .signIn
            }
        }
    }
}
