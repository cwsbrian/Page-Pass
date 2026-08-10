import Observation
import PhotosUI
import SwiftUI

struct ParentTabView: View {
    var onSignOut: (() async -> Void)?
    var onDeleteAccount: (() async -> String?)?
    var parent: ParentIdentity?
    @State private var store: ParentHomeStore

    init(
        parent: ParentIdentity? = nil,
        onSignOut: (() async -> Void)? = nil,
        onDeleteAccount: (() async -> String?)? = nil
    ) {
        self.parent = parent
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
        _store = State(
            initialValue: ParentHomeStore(onUnauthorized: onSignOut)
        )
    }

    var body: some View {
        TabView {
            ParentHomeView(store: store)
                .tabItem { Label("Home", systemImage: "house") }

            ParentRequestsView(store: store)
                .tabItem { Label("Requests", systemImage: "tray.full") }
                .badge(pendingRequestCount)

            ParentJournalView(store: store)
                .tabItem { Label("Journal", systemImage: "books.vertical") }

            ParentMoreView(
                store: store,
                parent: parent,
                onSignOut: onSignOut,
                onDeleteAccount: onDeleteAccount
            )
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private var pendingRequestCount: Int {
        let reading = store.readingSubmissionsByChild.values
            .flatMap { $0 }
            .filter { $0.status == "pending" }
            .count
        let apps = store.appAccessByChild.values
            .flatMap(\.requests)
            .filter { $0.status == "pending" }
            .count
        return reading + apps
    }
}

struct ChildTabView: View {
    let onResetInstallation: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = ChildTab.home
    @State private var runtime = ChildRuntimeStore()
    @State private var push = PagePassPushCoordinator.shared
    @State private var pushRegistration = ChildPushRegistrationStore()
    @State private var journalDeepLinkID: String?
    @State private var journalRefreshRevision = 0
    @State private var readingRevisionRequest: ReadingRevisionRequest?

    var body: some View {
        TabView(selection: $selectedTab) {
            ChildHomeView(
                runtime: runtime,
                onOpenEarn: { selectedTab = .earn },
                onOpenMore: { selectedTab = .more }
            )
                .tabItem { Label("Home", systemImage: "house") }
                .tag(ChildTab.home)

            NavigationStack {
                HandwrittenReportOCRView(
                    revisionRequest: $readingRevisionRequest
                )
            }
            .tabItem { Label("Earn", systemImage: "book.badge.plus") }
            .tag(ChildTab.earn)

            ChildJournalView(
                deepLinkSubmissionID: $journalDeepLinkID,
                refreshRevision: journalRefreshRevision,
                onContinueDraft: { selectedTab = .earn },
                onReviseRejected: {
                    readingRevisionRequest = ReadingRevisionRequest(
                        submissionID: $0.id,
                        bookTitle: $0.bookTitle ?? "",
                        author: $0.author ?? ""
                    )
                    selectedTab = .earn
                }
            )
                .tabItem { Label("Journal", systemImage: "books.vertical") }
                .tag(ChildTab.journal)

            ChildMoreView(
                store: runtime.session,
                pairingStore: runtime.pairing,
                runtime: runtime,
                onResetInstallation: onResetInstallation
            )
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(ChildTab.more)
        }
        .task {
            await runtime.load()
        }
        .task {
            await pushRegistration.register(token: push.deviceToken)
            await push.requestRegistration()
        }
        .task(id: runtime.session.activeSession?.id) {
            guard let session = runtime.session.activeSession else { return }
            let delay = max(0, session.expiresAt.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            runtime.reconcile()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runtime.reconcile()
            if runtime.pairing.isPaired {
                Task { await runtime.sync() }
            }
        }
        .onChange(of: runtime.session.pendingSettlements.count) { _, count in
            if count > 0, runtime.pairing.isPaired {
                Task { await runtime.sync() }
            }
        }
        .onChange(of: push.deviceToken) { _, token in
            Task { await pushRegistration.register(token: token) }
        }
        .onChange(of: push.eventRevision) { _, _ in
            handlePushEvent()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .pagePassChildCredentialChanged
            )
        ) { _ in
            Task { await pushRegistration.register(token: push.deviceToken) }
        }
    }

    private func handlePushEvent() {
        guard push.eventType == "reading_submission_reviewed" else { return }
        journalRefreshRevision &+= 1
        guard let submissionID = push.readingSubmissionID else { return }
        journalDeepLinkID = submissionID
        selectedTab = .journal
        push.clearReadingDeepLink()
    }
}

private enum ChildTab: Hashable {
    case home
    case earn
    case journal
    case more
}

private struct ParentRequestsView: View {
    @Bindable var store: ParentHomeStore
    @State private var selectedChildID = "all"
    @State private var selectedType = "all"
    @State private var selectedStatus = "pending"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Child", selection: $selectedChildID) {
                        Text("All Children").tag("all")
                        ForEach(store.children) { child in
                            Text(child.name).tag(child.id)
                        }
                    }

                    Picker("Type", selection: $selectedType) {
                        Text("All").tag("all")
                        Text("Reading").tag("reading")
                        Text("Apps").tag("app")
                    }
                    .pickerStyle(.segmented)

                    Picker("Status", selection: $selectedStatus) {
                        Text("Pending").tag("pending")
                        Text("Resolved").tag("resolved")
                        Text("All").tag("all")
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(items) { item in
                    requestRow(item)
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        selectedStatus == "pending"
                            ? "No Pending Requests"
                            : "No Matching Requests",
                        systemImage: "checkmark.circle"
                    )
                }
            }
            .navigationTitle("Requests")
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
        }
    }

    private var items: [ParentRequestItem] {
        store.children.flatMap { child in
            let reading = (store.readingSubmissionsByChild[child.id] ?? []).map {
                ParentRequestItem.reading(child: child, submission: $0)
            }
            let apps = (store.appAccessByChild[child.id]?.requests ?? []).map {
                ParentRequestItem.app(child: child, request: $0)
            }
            return reading + apps
        }
        .filter { selectedChildID == "all" || $0.child.id == selectedChildID }
        .filter { selectedType == "all" || $0.type == selectedType }
        .filter {
            selectedStatus == "all" ||
                (selectedStatus == "pending" ? $0.isPending : !$0.isPending)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    @ViewBuilder
    private func requestRow(_ item: ParentRequestItem) -> some View {
        switch item {
        case let .reading(child, submission):
            NavigationLink {
                ParentReadingReviewView(
                    childID: child.id,
                    submission: submission,
                    store: store
                )
            } label: {
                requestLabel(
                    title: submission.bookTitle ?? "Untitled Book",
                    child: child,
                    type: "Reading",
                    status: submission.status.readingStatusName,
                    symbol: "book.pages"
                )
            }
        case let .app(child, request):
            NavigationLink {
                ParentChildAppAccessView(child: child, store: store)
            } label: {
                requestLabel(
                    title: "App Access Request",
                    child: child,
                    type: "App",
                    status: request.status == "pending" ? "Pending" : "Resolved",
                    symbol: "square.grid.2x2"
                )
            }
        }
    }

    private func requestLabel(
        title: String,
        child: ChildSummary,
        type: String,
        status: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("\(child.name)  |  \(type)  |  \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum ParentRequestItem: Identifiable {
    case reading(child: ChildSummary, submission: ReadingSubmissionResponse)
    case app(child: ChildSummary, request: AppRequestResponse)

    var id: String {
        switch self {
        case let .reading(_, submission): "reading:\(submission.id)"
        case let .app(_, request): "app:\(request.id)"
        }
    }

    var child: ChildSummary {
        switch self {
        case let .reading(child, _), let .app(child, _): child
        }
    }

    var type: String {
        switch self {
        case .reading: "reading"
        case .app: "app"
        }
    }

    var isPending: Bool {
        switch self {
        case let .reading(_, submission): submission.status == "pending"
        case let .app(_, request): request.status == "pending"
        }
    }

    var timestamp: String {
        switch self {
        case let .reading(_, submission): submission.updatedAt
        case let .app(_, request): request.decidedAt ?? request.requestedAt
        }
    }
}

private struct ParentJournalView: View {
    @Bindable var store: ParentHomeStore
    @State private var query = ""
    @State private var selectedChildID = "all"
    @State private var selectedStatus = "all"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Child", selection: $selectedChildID) {
                        Text("All Children").tag("all")
                        ForEach(store.children) { child in
                            Text(child.name).tag(child.id)
                        }
                    }
                    Picker("Status", selection: $selectedStatus) {
                        Text("All").tag("all")
                        Text("Pending").tag("pending")
                        Text("Approved").tag("approved")
                        Text("Changes").tag("changes_requested")
                        Text("Rejected").tag("rejected")
                    }
                }

                ForEach(items) { item in
                    NavigationLink {
                        ParentReadingReviewView(
                            childID: item.child.id,
                            submission: item.submission,
                            store: store
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.submission.bookTitle ?? "Untitled Book")
                                .font(.headline)
                            HStack {
                                Text(item.child.name)
                                Spacer()
                                Label(
                                    item.submission.status.readingStatusName,
                                    systemImage: item.submission.status.readingStatusSymbol
                                )
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Journal")
            .searchable(text: $query, prompt: "Book title")
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
        }
    }

    private var items: [ParentJournalItem] {
        store.children.flatMap { child in
            (store.readingSubmissionsByChild[child.id] ?? []).map {
                ParentJournalItem(child: child, submission: $0)
            }
        }
        .filter { selectedChildID == "all" || $0.child.id == selectedChildID }
        .filter { selectedStatus == "all" || $0.submission.status == selectedStatus }
        .filter {
            query.isEmpty || ($0.submission.bookTitle ?? "")
                .localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.submission.updatedAt > $1.submission.updatedAt }
    }
}

private struct ParentJournalItem: Identifiable {
    let child: ChildSummary
    let submission: ReadingSubmissionResponse
    var id: String { submission.id }
}

private struct ParentMoreView: View {
    @Bindable var store: ParentHomeStore
    let parent: ParentIdentity?
    let onSignOut: (() async -> Void)?
    let onDeleteAccount: (() async -> String?)?
    @State private var showingSignOutConfirmation = false
    @State private var showingAccountDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let parent {
                        LabeledContent("Name", value: parent.displayName)
                    }

                    if onSignOut != nil {
                        Button(role: .destructive) {
                            showingSignOutConfirmation = true
                        } label: {
                            Label(
                                "Sign Out",
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                        }
                    }

                    if onDeleteAccount != nil {
                        Button(role: .destructive) {
                            showingAccountDeletion = true
                        } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
                }

                Section("Privacy and Support") {
                    NavigationLink {
                        PagePassTroubleshootingView()
                    } label: {
                        Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                    }
                    NavigationLink {
                        PagePassLegalDocumentView(document: .privacy)
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        PagePassLegalDocumentView(document: .terms)
                    } label: {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                    NavigationLink {
                        PagePassAboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

                Section("Family") {
                    NavigationLink {
                        ManageChildrenView(store: store)
                    } label: {
                        Label("Manage Children", systemImage: "person.2")
                    }
                    NavigationLink {
                        FamilySettingsView(store: store)
                    } label: {
                        Label("Earned Time and Rewards", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        ParentNotificationSettingsView(store: store)
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }

            }
            .navigationTitle("More")
            .confirmationDialog(
                "Sign out of PagePass?",
                isPresented: $showingSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await onSignOut?() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingAccountDeletion) {
                DeleteParentAccountView(onDeleteAccount: onDeleteAccount)
            }
        }
    }
}

private struct ManageChildrenView: View {
    @Bindable var store: ParentHomeStore

    var body: some View {
        List {
            Section("Active") {
                if store.children.isEmpty {
                    ContentUnavailableView(
                        "No Active Children",
                        systemImage: "person.2.slash"
                    )
                }
                ForEach(store.children) { child in
                    NavigationLink {
                        ManageChildView(store: store, child: child)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.name)
                                .font(.headline)
                            HStack(spacing: 8) {
                                Text(formattedChildBalance(child.balanceSeconds))
                                if let deviceName = child.activeDeviceName {
                                    Text(deviceName)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !store.archivedChildren.isEmpty {
                Section("Archived") {
                    ForEach(store.archivedChildren) { child in
                        NavigationLink {
                            ArchivedChildHistoryView(store: store, child: child)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(child.name)
                                    .font(.headline)
                                Text("Archived \(formattedArchiveDate(child.archivedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Children")
        .task {
            await store.refreshChildrenAndArchives()
        }
    }

    private func formattedChildBalance(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }

    private func formattedArchiveDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct ArchivedChildHistoryView: View {
    @Bindable var store: ParentHomeStore
    let child: ArchivedChildSummary

    private var submissions: [ReadingSubmissionResponse] {
        store.readingSubmissionsByChild[child.id] ?? []
    }

    private var ledger: [CreditLedgerEntryResponse] {
        store.ledgerByChild[child.id] ?? []
    }

    var body: some View {
        List {
            Section("Archive") {
                LabeledContent("Archived", value: formattedDate(child.archivedAt))
                LabeledContent("Remaining Balance", value: duration(child.balanceSeconds))
            }

            Section("Reading Reports") {
                if submissions.isEmpty {
                    ContentUnavailableView(
                        "No Reading Reports",
                        systemImage: "book.closed"
                    )
                } else {
                    ForEach(submissions) { submission in
                        NavigationLink {
                            ParentReadingReviewView(
                                childID: child.id,
                                submission: submission,
                                store: store,
                                isReadOnly: true
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(submission.bookTitle ?? "Untitled Book")
                                    .font(.headline)
                                Text(submission.status.readingStatusName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if store.readingNextCursorByChild[child.id] != nil {
                    Button {
                        Task { await store.loadMoreReading(childID: child.id) }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isWorking)
                }
            }

            Section("Balance History") {
                if ledger.isEmpty {
                    ContentUnavailableView(
                        "No Balance Activity",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else {
                    ForEach(ledger) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(ledgerTitle(entry.entryType))
                                    .font(.headline)
                                Spacer()
                                Text(signedDuration(entry.amountSeconds))
                                    .font(.headline)
                                    .monospacedDigit()
                            }
                            if let reason = entry.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(formattedDate(entry.createdAt))
                                Spacer()
                                Text("Balance \(duration(entry.balanceAfterSeconds))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if store.ledgerNextCursorByChild[child.id] != nil {
                    Button {
                        Task { await store.loadMoreLedger(childID: child.id) }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .disabled(store.isWorking)
                }
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PagePassTheme.error)
                }
            }
        }
        .navigationTitle(child.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshArchivedHistory(childID: child.id) }
    }

    private func ledgerTitle(_ value: String) -> String {
        switch value {
        case "parent_grant": String(localized: "Parent Added Time")
        case "reading_reward": String(localized: "Reading Reward")
        case "session_spend": String(localized: "Earned Time Used")
        case "parent_adjustment": String(localized: "Parent Adjustment")
        default: String(localized: "Balance Updated")
        }
    }

    private func signedDuration(_ seconds: Int) -> String {
        let sign = seconds > 0 ? "+" : seconds < 0 ? "-" : ""
        return sign + duration(abs(seconds))
    }

    private func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)
        )
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ManageChildView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ParentHomeStore
    let child: ChildSummary
    @State private var name: String
    @State private var showingArchiveConfirmation = false

    init(store: ParentHomeStore, child: ChildSummary) {
        self.store = store
        self.child = child
        _name = State(initialValue: child.name)
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
                    .textContentType(.name)
                Button {
                    Task { _ = await store.updateChild(childID: child.id, name: name) }
                } label: {
                    Label("Save Name", systemImage: "checkmark")
                }
                .disabled(store.isWorking || normalizedName == child.name)
            }

            Section {
                Button(role: .destructive) {
                    showingArchiveConfirmation = true
                } label: {
                    Label("Archive Child", systemImage: "archivebox")
                }
                .disabled(store.isWorking)
            } header: {
                Text("Archive")
            } footer: {
                Text("Reading and earned-time records are preserved. Server access is disconnected immediately, and PagePass restrictions clear when the child next opens PagePass.")
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(PagePassTheme.error)
                }
            }
        }
        .navigationTitle(child.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Archive \(child.name)?",
            isPresented: $showingArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Archive Child", role: .destructive) {
                Task {
                    if await store.archiveChild(childID: child.id) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects server access and keeps reading and earned-time history. PagePass restrictions clear when the child next opens PagePass.")
        }
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ParentNotificationSettingsView: View {
    @Bindable var store: ParentHomeStore
    @State private var readingRequests = true
    @State private var appRequests = true
    @State private var deviceAlerts = true
    @State private var sessionEnded = true
    @State private var didLoad = false
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section("Requests") {
                Toggle("Reading Reports", isOn: $readingRequests)
                Toggle("App Requests", isOn: $appRequests)
            }

            Section("Activity") {
                Toggle("Device Alerts", isOn: $deviceAlerts)
                Toggle("Earned Time Ended", isOn: $sessionEnded)
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    Label("Save Settings", systemImage: "checkmark")
                }
                .disabled(store.isWorking)

                if let savedMessage {
                    Text(savedMessage)
                        .foregroundStyle(.green)
                }
                if let error = store.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            if store.parentPreferences == nil {
                await store.refreshParentPreferences()
            }
            loadOnce()
        }
        .onChange(of: readingRequests) { savedMessage = nil }
        .onChange(of: appRequests) { savedMessage = nil }
        .onChange(of: deviceAlerts) { savedMessage = nil }
        .onChange(of: sessionEnded) { savedMessage = nil }
    }

    private func loadOnce() {
        guard !didLoad, let preferences = store.parentPreferences else { return }
        didLoad = true
        readingRequests = preferences.readingRequestsEnabled
        appRequests = preferences.appRequestsEnabled
        deviceAlerts = preferences.deviceAlertsEnabled
        sessionEnded = preferences.sessionEndedEnabled
    }

    private func save() async {
        let saved = await store.updateParentPreferences(
            readingRequestsEnabled: readingRequests,
            appRequestsEnabled: appRequests,
            deviceAlertsEnabled: deviceAlerts,
            sessionEndedEnabled: sessionEnded
        )
        savedMessage = saved ? "Notification settings saved." : nil
    }
}

private struct FamilySettingsView: View {
    @Bindable var store: ParentHomeStore
    @State private var rewardSeconds = 900
    @State private var selectedPresets = Set([900, 1_800, 3_600])
    @State private var didLoad = false
    @State private var savedMessage: String?

    private let availablePresets = [300, 900, 1_800, 3_600]

    var body: some View {
        Form {
            Section("Earned Time Choices") {
                ForEach(availablePresets, id: \.self) { seconds in
                    Toggle(durationLabel(seconds), isOn: presetBinding(seconds))
                }
                Text("Children can also choose Max to use their full balance.")
                    .foregroundStyle(.secondary)
            }

            Section("Reading Approval") {
                Picker("Default Reward", selection: $rewardSeconds) {
                    ForEach(availablePresets, id: \.self) { seconds in
                        Text(durationLabel(seconds)).tag(seconds)
                    }
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    Label("Save Settings", systemImage: "checkmark")
                }
                .disabled(selectedPresets.isEmpty || store.isWorking)

                if let savedMessage {
                    Text(savedMessage)
                        .foregroundStyle(.green)
                }
                if let error = store.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Family Settings")
        .task {
            if store.familyPreferences == nil {
                await store.refreshFamilyPreferences()
            }
            loadOnce()
        }
    }

    private func presetBinding(_ seconds: Int) -> Binding<Bool> {
        Binding(
            get: { selectedPresets.contains(seconds) },
            set: { enabled in
                if enabled {
                    selectedPresets.insert(seconds)
                } else if selectedPresets.count > 1 {
                    selectedPresets.remove(seconds)
                }
                savedMessage = nil
            }
        )
    }

    private func loadOnce() {
        guard !didLoad, let preferences = store.familyPreferences else { return }
        didLoad = true
        rewardSeconds = preferences.defaultReadingRewardSeconds
        selectedPresets = Set(preferences.sessionPresetSeconds)
    }

    private func save() async {
        let saved = await store.updateFamilyPreferences(
            defaultReadingRewardSeconds: rewardSeconds,
            sessionPresetSeconds: selectedPresets.sorted()
        )
        savedMessage = saved ? "Settings saved." : nil
    }

    private func durationLabel(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .wide)
        )
    }
}

private struct DeleteParentAccountView: View {
    let onDeleteAccount: (() async -> String?)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes your parent account. If you are the last parent, PagePass also disconnects the children's devices and removes their personal reading data.")
                    Text("Another parent keeps access to a shared family. Active Earned Time must be stopped before the last parent can delete the account.")
                }

                Section("Confirmation") {
                    TextField("Type DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    Button("Delete Account", role: .destructive) {
                        Task { await deleteAccount() }
                    }
                    .disabled(confirmation != "DELETE" || isDeleting)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isDeleting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    private func deleteAccount() async {
        guard !isDeleting, let onDeleteAccount else { return }
        isDeleting = true
        errorMessage = await onDeleteAccount()
        isDeleting = false
        if errorMessage == nil {
            dismiss()
        }
    }
}

@MainActor
@Observable
private final class ChildJournalStore {
    private(set) var submissions: [ReadingSubmissionResponse] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let credentials = DeviceCredentialStore()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let credential = try await credentials.load() else {
                throw ChildJournalError.deviceNotPaired
            }
            submissions = try await PagePassRuntimeConfiguration.apiClient(
                serverURLString: PagePassRuntimeConfiguration.serverURLString
            ).childReadingSubmissions(deviceCredential: credential)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replace(_ submission: ReadingSubmissionResponse) {
        guard let index = submissions.firstIndex(where: {
            $0.id == submission.id
        }) else { return }
        submissions[index] = submission
    }

    func remove(submissionID: String) {
        submissions.removeAll { $0.id == submissionID }
    }
}

private struct ChildJournalView: View {
    @Binding var deepLinkSubmissionID: String?
    let refreshRevision: Int
    let onContinueDraft: () -> Void
    let onReviseRejected: (ReadingSubmissionResponse) -> Void
    @State private var store = ChildJournalStore()
    @State private var query = ""
    @State private var deepLinkedSubmission: ReadingSubmissionResponse?
    @State private var isDeepLinkPresented = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { submission in
                    NavigationLink {
                        ChildReadingDetailView(
                            submission: submission,
                            onUpdated: { store.replace($0) },
                            onDeleted: { store.remove(submissionID: $0) },
                            onContinueDraft: onContinueDraft,
                            onReviseRejected: onReviseRejected
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(submission.bookTitle ?? "Untitled Book")
                                .font(.headline)
                            Label(
                                submission.status.readingStatusName,
                                systemImage: submission.status.readingStatusSymbol
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = store.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("Journal")
            .searchable(text: $query, prompt: "Book title")
            .overlay {
                if store.isLoading && store.submissions.isEmpty {
                    ProgressView()
                }
            }
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
            .navigationDestination(isPresented: $isDeepLinkPresented) {
                if let submission = deepLinkedSubmission {
                    ChildReadingDetailView(
                        submission: submission,
                        onUpdated: {
                            store.replace($0)
                            deepLinkedSubmission = $0
                        },
                        onDeleted: {
                            store.remove(submissionID: $0)
                            deepLinkedSubmission = nil
                            isDeepLinkPresented = false
                        },
                        onContinueDraft: onContinueDraft,
                        onReviseRejected: onReviseRejected
                    )
                }
            }
            .task(id: refreshRevision) {
                await store.refresh()
                openDeepLinkIfAvailable()
            }
            .onChange(of: deepLinkSubmissionID) { _, _ in
                openDeepLinkIfAvailable()
            }
        }
    }

    private var items: [ReadingSubmissionResponse] {
        store.submissions.filter {
            query.isEmpty || ($0.bookTitle ?? "")
                .localizedCaseInsensitiveContains(query)
        }
    }

    private func openDeepLinkIfAvailable() {
        guard let submissionID = deepLinkSubmissionID,
              let submission = store.submissions.first(where: {
                  $0.id == submissionID
              }) else { return }
        deepLinkedSubmission = submission
        isDeepLinkPresented = true
        deepLinkSubmissionID = nil
    }
}

@MainActor
@Observable
private final class ChildReadingDetailStore {
    private(set) var submission: ReadingSubmissionResponse
    private(set) var mediaURLs: [String: URL] = [:]
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var canContinueDraft = false
    var correctedTranscript: String

    private let credentials = DeviceCredentialStore()
    private let recoveryStore = ReadingDraftRecoveryStore()

    init(submission: ReadingSubmissionResponse) {
        self.submission = submission
        correctedTranscript = Self.transcript(for: submission)
        canContinueDraft = Self.hasMatchingRecovery(
            submissionID: submission.id,
            recoveryStore: recoveryStore
        )
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (client, credential) = try await context()
            submission = try await client.childReadingSubmission(
                submissionID: submission.id,
                deviceCredential: credential
            )
            canContinueDraft = Self.hasMatchingRecovery(
                submissionID: submission.id,
                recoveryStore: recoveryStore
            )
            correctedTranscript = Self.transcript(for: submission)
            var urls: [String: URL] = [:]
            for evidence in submission.evidence {
                urls[evidence.originalMediaId] = try await client
                    .childReadingMediaURL(
                        mediaID: evidence.originalMediaId,
                        deviceCredential: credential
                    ).url
            }
            mediaURLs = urls
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resubmit() async -> ReadingSubmissionResponse? {
        guard !isSubmitting, submission.status == "changes_requested" else {
            return nil
        }
        isSubmitting = true
        errorMessage = nil
        noticeMessage = nil
        defer { isSubmitting = false }
        do {
            let (client, credential) = try await context()
            var current = try await client.childReadingSubmission(
                submissionID: submission.id,
                deviceCredential: credential
            )
            guard current.status == "changes_requested" else {
                submission = current
                throw ChildJournalError.submissionChanged
            }
            if correctedTranscript != Self.transcript(for: current) {
                current = try await client.updateReadingTranscript(
                    submissionID: current.id,
                    correctedOCRText: correctedTranscript,
                    expectedVersion: current.version,
                    deviceCredential: credential
                )
            }
            current = try await client.resubmitReadingSubmission(
                submissionID: current.id,
                expectedVersion: current.version,
                deviceCredential: credential
            )
            submission = current
            correctedTranscript = Self.transcript(for: current)
            noticeMessage = "Sent back to your parent for review."
            return current
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func apply(_ submission: ReadingSubmissionResponse) {
        self.submission = submission
        correctedTranscript = Self.transcript(for: submission)
        noticeMessage = "Sent back to your parent for review."
        errorMessage = nil
    }

    func deleteDraft() async -> Bool {
        guard !isSubmitting, submission.status == "draft" else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let (client, credential) = try await context()
            try await client.deleteReadingDraft(
                submissionID: submission.id,
                deviceCredential: credential
            )
            try? recoveryStore.remove(
                ifServerSubmissionIDMatches: submission.id
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func context() async throws -> (PagePassAPIClient, String) {
        guard let credential = try await credentials.load() else {
            throw ChildJournalError.deviceNotPaired
        }
        return (
            try PagePassRuntimeConfiguration.apiClient(
                serverURLString: PagePassRuntimeConfiguration.serverURLString
            ),
            credential
        )
    }

    private static func transcript(
        for submission: ReadingSubmissionResponse
    ) -> String {
        if let corrected = submission.correctedOcrText, !corrected.isEmpty {
            return corrected
        }
        return submission.evidence
            .sorted { $0.pageOrder < $1.pageOrder }
            .compactMap(\.rawOcrText)
            .joined(separator: "\n\n")
    }

    private static func hasMatchingRecovery(
        submissionID: String,
        recoveryStore: ReadingDraftRecoveryStore
    ) -> Bool {
        (try? recoveryStore.load()?.serverSubmissionID == submissionID) ?? false
    }
}

private struct ChildReadingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: ChildReadingDetailStore
    @State private var replacementOCR = HandwrittenReportOCRStore()
    @State private var replacementSubmission = ReadingSubmissionStore()
    @State private var selectedReplacementPhotos: [PhotosPickerItem] = []
    @State private var isDeleteConfirmationPresented = false
    let onUpdated: (ReadingSubmissionResponse) -> Void
    let onDeleted: (String) -> Void
    let onContinueDraft: () -> Void
    let onReviseRejected: (ReadingSubmissionResponse) -> Void

    init(
        submission: ReadingSubmissionResponse,
        onUpdated: @escaping (ReadingSubmissionResponse) -> Void,
        onDeleted: @escaping (String) -> Void = { _ in },
        onContinueDraft: @escaping () -> Void = {},
        onReviseRejected: @escaping (ReadingSubmissionResponse) -> Void = { _ in }
    ) {
        _store = State(initialValue: ChildReadingDetailStore(submission: submission))
        self.onUpdated = onUpdated
        self.onDeleted = onDeleted
        self.onContinueDraft = onContinueDraft
        self.onReviseRejected = onReviseRejected
    }

    var body: some View {
        List {
            Section("Book") {
                LabeledContent(
                    "Title",
                    value: store.submission.bookTitle ?? "Untitled"
                )
                if let author = store.submission.author {
                    LabeledContent("Author", value: author)
                }
                LabeledContent(
                    "Status",
                    value: store.submission.status.readingStatusName
                )
            }

            if !store.submission.evidence.isEmpty {
                Section("Handwritten Report") {
                    ForEach(
                        store.submission.evidence.sorted {
                            $0.pageOrder < $1.pageOrder
                        }
                    ) { evidence in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Page \(evidence.pageOrder + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let url = store.mediaURLs[evidence.originalMediaId] {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case let .success(image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                    case .failure:
                                        ContentUnavailableView(
                                            "Page Unavailable",
                                            systemImage: "photo.badge.exclamationmark"
                                        )
                                    case .empty:
                                        ProgressView()
                                            .frame(maxWidth: .infinity, minHeight: 180)
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            }
                        }
                    }
                }
            }

            if store.submission.status == "changes_requested" {
                replacementPagesSection
            }

            Section("Transcript") {
                if store.submission.status == "changes_requested" {
                    TextEditor(text: $store.correctedTranscript)
                        .frame(minHeight: 180)
                    Button {
                        Task {
                            if let updated = await store.resubmit() {
                                onUpdated(updated)
                            }
                        }
                    } label: {
                        Label("Resubmit for Review", systemImage: "paperplane.fill")
                    }
                    .disabled(store.isSubmitting)
                } else {
                    Text(
                        store.correctedTranscript.isEmpty
                            ? "No text recognized"
                            : store.correctedTranscript
                    )
                    .textSelection(.enabled)
                }
            }

            if !store.submission.reviews.isEmpty {
                Section("Parent Review") {
                    ForEach(store.submission.reviews) { review in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                review.decision.readingStatusName,
                                systemImage: review.decision.readingStatusSymbol
                            )
                            if let comment = review.comment {
                                Text(comment).foregroundStyle(.secondary)
                            }
                            if review.rewardSeconds > 0 {
                                Text(Duration.seconds(review.rewardSeconds).formatted())
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            Section("Timeline") {
                LabeledContent("Created", value: store.submission.createdAt)
                if let submittedAt = store.submission.submittedAt {
                    LabeledContent("Submitted", value: submittedAt)
                }
                if let reviewedAt = store.submission.reviewedAt {
                    LabeledContent("Reviewed", value: reviewedAt)
                }
            }

            if store.submission.status == "draft" {
                Section {
                    if store.canContinueDraft {
                        Button {
                            dismiss()
                            onContinueDraft()
                        } label: {
                            Label("Continue in Earn", systemImage: "arrow.right.circle")
                        }
                    }
                    Button("Delete Draft", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .disabled(store.isSubmitting)
                }
            }

            if store.submission.status == "rejected" {
                Section {
                    Button {
                        let submission = store.submission
                        dismiss()
                        onReviseRejected(submission)
                    } label: {
                        Label("Create Revised Report", systemImage: "doc.badge.plus")
                    }
                }
            }

            if let message = store.noticeMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(store.submission.bookTitle ?? "Reading Report")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isLoading {
                ProgressView()
            }
        }
        .task { await store.load() }
        .onChange(of: selectedReplacementPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadReplacementPhotos(items) }
        }
        .confirmationDialog(
            "Delete this draft?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Draft", role: .destructive) {
                Task {
                    guard await store.deleteDraft() else { return }
                    onDeleted(store.submission.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The uploaded pages and saved recovery data will be removed.")
        }
    }

    private var replacementPagesSection: some View {
        Section("Replace Handwritten Pages") {
            PhotosPicker(
                selection: $selectedReplacementPhotos,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                Label("Choose New Pages", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(
                replacementOCR.isProcessing ||
                replacementSubmission.isSubmitting
            )

            ForEach(Array(replacementOCR.pages.enumerated()), id: \.element.id) {
                index, page in
                HStack {
                    Text("Page \(index + 1)")
                    Spacer()
                    Text(replacementStatus(page.state))
                        .foregroundStyle(.secondary)
                }
            }

            if replacementSubmission.hasRecoverableDraft,
               replacementSubmission.recoverableDraft?.serverSubmissionID ==
                store.submission.id {
                Button {
                    Task {
                        await replacementSubmission.resumeRecoverableDraft()
                        applyCompletedReplacement()
                    }
                } label: {
                    Label("Retry Page Replacement", systemImage: "arrow.clockwise")
                }
            } else if !replacementOCR.pages.isEmpty {
                Button {
                    Task {
                        await replacementSubmission.replacePagesAndResubmit(
                            submission: store.submission,
                            pages: replacementOCR.pages,
                            rawTranscript: replacementOCR.rawTranscript,
                            correctedTranscript: replacementOCR.correctedTranscript,
                            isTranscriptEdited: replacementOCR.isTranscriptEdited
                        )
                        applyCompletedReplacement()
                    }
                } label: {
                    Label("Replace Pages and Resubmit", systemImage: "paperplane.fill")
                }
                .disabled(
                    replacementOCR.isProcessing ||
                    replacementSubmission.isSubmitting
                )
            }

            if let progress = replacementSubmission.progressMessage {
                HStack {
                    ProgressView()
                    Text(progress)
                }
            }
            if let message = replacementSubmission.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadReplacementPhotos(_ items: [PhotosPickerItem]) async {
        var pages: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                pages.append(data)
            }
        }
        guard !pages.isEmpty else {
            replacementOCR.reportCaptureError(
                "The selected photos could not be loaded."
            )
            return
        }
        await replacementOCR.recognizeNewPages(pages)
    }

    private func applyCompletedReplacement() {
        guard let submission = replacementSubmission.submittedReport else { return }
        store.apply(submission)
        onUpdated(submission)
        replacementOCR.clear()
        selectedReplacementPhotos = []
    }

    private func replacementStatus(_ state: HandwrittenReportPageState) -> String {
        switch state {
        case .pending: "Pending"
        case .processing: "Recognizing"
        case .completed: "Ready"
        case .failed: "OCR Failed"
        }
    }
}

private enum ChildJournalError: LocalizedError {
    case deviceNotPaired
    case submissionChanged

    var errorDescription: String? {
        switch self {
        case .deviceNotPaired:
            "Connect this device to a child profile first."
        case .submissionChanged:
            "This report changed on the server. Review its latest status."
        }
    }
}
