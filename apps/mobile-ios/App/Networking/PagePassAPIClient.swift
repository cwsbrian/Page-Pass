import Foundation
import PagePassCore

struct PagePassAPIClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidServerURL
        case invalidResponse
        case deviceRevoked(message: String)
        case server(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter a valid PagePass server URL."
            case .invalidResponse:
                "The PagePass server returned an invalid response."
            case let .deviceRevoked(message):
                message
            case let .server(_, message):
                message
            }
        }
    }

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .pagePass) {
        self.baseURL = baseURL
        self.session = session
    }

    func signUpParent(
        name: String,
        email: String,
        password: String
    ) async throws -> BetterAuthCredentialResponse {
        try await request(
            BetterAuthCredentialResponse.self,
            path: "api/auth/sign-up/email",
            method: "POST",
            body: BetterAuthSignUpBody(
                name: name,
                email: email,
                password: password,
                callbackURL: "pagepass://auth/email-verified"
            )
        )
    }

    func signInParent(
        email: String,
        password: String
    ) async throws -> BetterAuthCredentialResponse {
        try await request(
            BetterAuthCredentialResponse.self,
            path: "api/auth/sign-in/email",
            method: "POST",
            body: BetterAuthSignInBody(
                email: email,
                password: password,
                rememberMe: true
            )
        )
    }

    func resendParentVerification(email: String) async throws {
        _ = try await request(
            BetterAuthStatusResponse.self,
            path: "api/auth/send-verification-email",
            method: "POST",
            body: BetterAuthVerificationBody(
                email: email,
                callbackURL: "pagepass://auth/email-verified"
            )
        )
    }

    func requestParentPasswordReset(email: String) async throws {
        _ = try await request(
            BetterAuthStatusResponse.self,
            path: "api/auth/request-password-reset",
            method: "POST",
            body: BetterAuthPasswordResetRequestBody(
                email: email,
                redirectTo: "pagepass://auth/reset-password"
            )
        )
    }

    func resetParentPassword(token: String, newPassword: String) async throws {
        _ = try await request(
            BetterAuthStatusResponse.self,
            path: "api/auth/reset-password",
            method: "POST",
            body: BetterAuthPasswordResetBody(
                newPassword: newPassword,
                token: token
            )
        )
    }

    func signOutParent(parentToken: String) async throws {
        try await requestWithoutResponse(
            path: "api/auth/sign-out",
            method: "POST",
            bearer: parentToken
        )
    }

    func deleteParentAccount(parentToken: String) async throws {
        try await requestWithoutResponse(
            path: "v1/parent/account",
            method: "DELETE",
            bearer: parentToken
        )
    }

    func appleAuthChallenge() async throws -> AppleAuthChallengeResponse {
        try await request(
            AppleAuthChallengeResponse.self,
            path: "v1/auth/apple/challenges",
            method: "POST",
            body: EmptyBody()
        )
    }

    func createParentSession(
        challengeID: String,
        state: String,
        identityToken: String,
        displayName: String?
    ) async throws -> ParentSessionResponse {
        try await request(
            ParentSessionResponse.self,
            path: "v1/auth/apple/sessions",
            method: "POST",
            body: AppleSessionBody(
                challengeId: challengeID,
                state: state,
                identityToken: identityToken,
                displayName: displayName
            )
        )
    }

    func parentIdentity(parentToken: String) async throws -> ParentIdentity {
        try await request(
            ParentIdentity.self,
            path: "v1/parent/me",
            bearer: parentToken
        )
    }

    func claimLocalData(
        localParentToken: String,
        parentToken: String
    ) async throws -> ClaimLocalDataResponse {
        try await request(
            ClaimLocalDataResponse.self,
            path: "v1/parent/claim-local-data",
            method: "POST",
            bearer: parentToken,
            body: ClaimLocalDataBody(localParentToken: localParentToken)
        )
    }

    func revokeParentSession(parentToken: String) async throws {
        try await requestWithoutResponse(
            path: "v1/auth/session",
            method: "DELETE",
            bearer: parentToken
        )
    }

    func children(parentToken: String) async throws -> [ChildSummary] {
        try await request(
            ChildrenResponse.self,
            path: "v1/parent/children",
            bearer: parentToken
        ).children
    }

    func archivedChildren(parentToken: String) async throws -> [ArchivedChildSummary] {
        try await request(
            ArchivedChildrenResponse.self,
            path: "v1/parent/children/archived",
            bearer: parentToken
        ).children
    }

    func parentHome(parentToken: String) async throws -> ParentHomeResponse {
        try await request(
            ParentHomeResponse.self,
            path: "v1/parent/home",
            bearer: parentToken
        )
    }

    func familyPreferences(parentToken: String) async throws -> FamilyPreferencesResponse {
        try await request(
            FamilyPreferencesResponse.self,
            path: "v1/parent/family/preferences",
            bearer: parentToken
        )
    }

    func updateFamilyPreferences(
        expectedVersion: Int,
        defaultReadingRewardSeconds: Int,
        sessionPresetSeconds: [Int],
        parentToken: String
    ) async throws -> FamilyPreferencesResponse {
        try await request(
            FamilyPreferencesResponse.self,
            path: "v1/parent/family/preferences",
            method: "PATCH",
            bearer: parentToken,
            body: UpdateFamilyPreferencesBody(
                expectedVersion: expectedVersion,
                defaultReadingRewardSeconds: defaultReadingRewardSeconds,
                sessionPresetSeconds: sessionPresetSeconds
            )
        )
    }

    func parentPreferences(parentToken: String) async throws -> ParentPreferencesResponse {
        try await request(
            ParentPreferencesResponse.self,
            path: "v1/parent/preferences",
            bearer: parentToken
        )
    }

    func updateParentPreferences(
        readingRequestsEnabled: Bool,
        appRequestsEnabled: Bool,
        deviceAlertsEnabled: Bool,
        sessionEndedEnabled: Bool,
        parentToken: String
    ) async throws -> ParentPreferencesResponse {
        try await request(
            ParentPreferencesResponse.self,
            path: "v1/parent/preferences",
            method: "PATCH",
            bearer: parentToken,
            body: UpdateParentPreferencesBody(
                readingRequestsEnabled: readingRequestsEnabled,
                appRequestsEnabled: appRequestsEnabled,
                deviceAlertsEnabled: deviceAlertsEnabled,
                sessionEndedEnabled: sessionEndedEnabled
            )
        )
    }

    func createChild(name: String, parentToken: String) async throws -> ChildSummary {
        try await request(
            ChildSummary.self,
            path: "v1/parent/children",
            method: "POST",
            bearer: parentToken,
            body: ["name": name]
        )
    }

    func updateChild(
        childID: String,
        name: String,
        parentToken: String
    ) async throws -> ChildSummary {
        try await request(
            ChildSummary.self,
            path: "v1/parent/children/\(childID)",
            method: "PATCH",
            bearer: parentToken,
            body: ["name": name]
        )
    }

    func archiveChild(
        childID: String,
        parentToken: String
    ) async throws {
        try await requestWithoutResponse(
            path: "v1/parent/children/\(childID)/archive",
            method: "POST",
            bearer: parentToken
        )
    }

    func createPairingSession(
        childID: String,
        parentToken: String
    ) async throws -> PairingSessionResponse {
        try await request(
            PairingSessionResponse.self,
            path: "v1/parent/children/\(childID)/pairing-sessions",
            method: "POST",
            bearer: parentToken,
            body: EmptyBody()
        )
    }

    func childDevices(
        childID: String,
        parentToken: String
    ) async throws -> [ParentChildDeviceResponse] {
        try await request(
            ParentChildDevicesResponse.self,
            path: "v1/parent/children/\(childID)/devices",
            bearer: parentToken
        ).devices
    }

    func reportChildDeviceStatus(
        _ body: ChildDeviceStatusBody,
        deviceCredential: String
    ) async throws -> ChildDeviceStatusResponse {
        try await request(
            ChildDeviceStatusResponse.self,
            path: "v1/child/device-status",
            method: "PUT",
            bearer: deviceCredential,
            body: body
        )
    }

    func revokeChildDevice(
        childID: String,
        deviceID: String,
        parentToken: String
    ) async throws {
        try await requestWithoutResponse(
            path: "v1/parent/children/\(childID)/devices/\(deviceID)/revoke",
            method: "POST",
            bearer: parentToken
        )
    }

    func registerParentPushDevice(
        installationID: String,
        token: String,
        environment: String,
        parentToken: String
    ) async throws -> ParentPushDeviceResponse {
        try await request(
            ParentPushDeviceResponse.self,
            path: "v1/parent/push-devices",
            method: "PUT",
            bearer: parentToken,
            body: ParentPushDeviceBody(
                installationId: installationID,
                token: token,
                environment: environment
            )
        )
    }

    func registerChildPushDevice(
        token: String,
        environment: String,
        deviceCredential: String
    ) async throws -> ChildPushDeviceResponse {
        try await request(
            ChildPushDeviceResponse.self,
            path: "v1/child/push-device",
            method: "PUT",
            bearer: deviceCredential,
            body: ChildPushDeviceBody(
                token: token,
                environment: environment
            )
        )
    }

    func grantCredit(
        childID: String,
        seconds: Int,
        reason: String,
        idempotencyKey: String,
        parentToken: String
    ) async throws -> CreditGrantResponse {
        try await request(
            CreditGrantResponse.self,
            path: "v1/parent/children/\(childID)/credit-grants",
            method: "POST",
            bearer: parentToken,
            body: CreditGrantBody(
                seconds: seconds,
                reason: reason,
                idempotencyKey: idempotencyKey
            )
        )
    }

    func childCreditLedger(
        childID: String,
        cursor: String? = nil,
        limit: Int = 25,
        parentToken: String
    ) async throws -> CreditLedgerResponse {
        guard var components = URLComponents(
            url: baseURL.appending(
                path: "v1/parent/children/\(childID)/ledger"
            ),
            resolvingAgainstBaseURL: false
        ) else {
            throw ClientError.invalidServerURL
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            cursor.map { URLQueryItem(name: "cursor", value: $0) }
        ].compactMap { $0 }
        guard let url = components.url else {
            throw ClientError.invalidServerURL
        }
        return try await request(
            CreditLedgerResponse.self,
            url: url,
            bearer: parentToken
        )
    }

    func pairDevice(
        installationID: String,
        deviceName: String,
        numericCode: String
    ) async throws -> PairingConsumeResponse {
        try await request(
            PairingConsumeResponse.self,
            path: "v1/pairing/consume",
            method: "POST",
            body: PairingBody(
                installationId: installationID,
                deviceName: deviceName,
                qrToken: nil,
                numericCode: numericCode
            )
        )
    }

    func pairDevice(
        installationID: String,
        deviceName: String,
        qrToken: String
    ) async throws -> PairingConsumeResponse {
        try await request(
            PairingConsumeResponse.self,
            path: "v1/pairing/consume",
            method: "POST",
            body: PairingBody(
                installationId: installationID,
                deviceName: deviceName,
                qrToken: qrToken,
                numericCode: nil
            )
        )
    }

    func childSnapshot(deviceCredential: String) async throws -> ChildSnapshotResponse {
        try await request(
            ChildSnapshotResponse.self,
            path: "v1/child/snapshot",
            bearer: deviceCredential
        )
    }

    func completeChildSetup(
        earnedTimeAppCount: Int,
        deviceCredential: String
    ) async throws -> ChildSnapshotResponse {
        try await request(
            ChildSnapshotResponse.self,
            path: "v1/child/setup/complete",
            method: "POST",
            bearer: deviceCredential,
            body: ChildSetupCompleteBody(
                earnedTimeAppCount: earnedTimeAppCount
            )
        )
    }

    func registerManagedApps(
        _ apps: [ManagedAppRegistrationItem],
        deviceCredential: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/child/managed-apps",
            method: "POST",
            bearer: deviceCredential,
            body: ManagedAppRegistrationBody(apps: apps)
        )
    }

    func childAppAccess(
        deviceCredential: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/child/app-access",
            bearer: deviceCredential
        )
    }

    func requestManagedApp(
        managedAppID: String,
        message: String?,
        idempotencyKey: String,
        deviceCredential: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/child/app-requests",
            method: "POST",
            bearer: deviceCredential,
            body: AppRequestBody(
                managedAppId: managedAppID,
                message: message,
                idempotencyKey: idempotencyKey
            )
        )
    }

    func acknowledgePolicy(
        policyVersion: Int,
        result: String,
        appliedAt: Date,
        failureReason: String?,
        deviceCredential: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/child/policy-acks",
            method: "POST",
            bearer: deviceCredential,
            body: PolicyAckBody(
                policyVersion: policyVersion,
                result: result,
                appliedAt: appliedAt,
                failureReason: failureReason
            )
        )
    }

    func parentAppAccess(
        childID: String,
        parentToken: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/parent/children/\(childID)/app-access",
            bearer: parentToken
        )
    }

    func decideAppRequest(
        requestID: String,
        policy: ManagedAppPolicyValue,
        expectedPolicyVersion: Int,
        expectedRequestVersion: Int,
        idempotencyKey: String,
        parentToken: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/parent/app-requests/\(requestID)/decision",
            method: "POST",
            bearer: parentToken,
            body: AppRequestDecisionBody(
                policy: policy,
                expectedPolicyVersion: expectedPolicyVersion,
                expectedRequestVersion: expectedRequestVersion,
                idempotencyKey: idempotencyKey
            )
        )
    }

    func updateAppPolicy(
        childID: String,
        managedAppID: String,
        policy: ManagedAppPolicyValue,
        expectedPolicyVersion: Int,
        idempotencyKey: String,
        parentToken: String
    ) async throws -> AppAccessResponse {
        try await request(
            AppAccessResponse.self,
            path: "v1/parent/children/\(childID)/app-policies/\(managedAppID)",
            method: "PUT",
            bearer: parentToken,
            body: AppPolicyUpdateBody(
                policy: policy,
                expectedPolicyVersion: expectedPolicyVersion,
                idempotencyKey: idempotencyKey
            )
        )
    }

    func startEarnedTimeSession(
        sessionID: UUID,
        requestedDurationSeconds: Int,
        balanceBeforeSeconds: Int,
        deviceCredential: String
    ) async throws -> EarnedTimeStartResponse {
        try await request(
            EarnedTimeStartResponse.self,
            path: "v1/child/earned-time-sessions/\(sessionID.uuidString.lowercased())/start",
            method: "POST",
            bearer: deviceCredential,
            body: EarnedTimeStartBody(
                requestedDurationSeconds: requestedDurationSeconds,
                balanceBeforeSeconds: balanceBeforeSeconds
            )
        )
    }

    func activateEarnedTimeSession(
        sessionID: UUID,
        deviceCredential: String
    ) async throws -> EarnedTimeStartResponse {
        try await request(
            EarnedTimeStartResponse.self,
            path: "v1/child/earned-time-sessions/\(sessionID.uuidString.lowercased())/activate",
            method: "POST",
            bearer: deviceCredential,
            body: EmptyBody()
        )
    }

    func settle(
        _ settlement: EarnedTimeSettlement,
        deviceCredential: String
    ) async throws -> EarnedTimeSettlementResponse {
        try await request(
            EarnedTimeSettlementResponse.self,
            path: "v1/child/earned-time-sessions/\(settlement.sessionID.uuidString.lowercased())",
            method: "PUT",
            bearer: deviceCredential,
            body: SettlementBody(settlement: settlement)
        )
    }

    func createReadingSubmission(
        bookTitle: String,
        author: String?,
        supersedesSubmissionID: String? = nil,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions",
            method: "POST",
            bearer: deviceCredential,
            body: CreateReadingSubmissionBody(
                bookTitle: bookTitle,
                author: author,
                supersedesSubmissionId: supersedesSubmissionID
            )
        )
    }

    func childReadingSubmissions(
        deviceCredential: String
    ) async throws -> [ReadingSubmissionResponse] {
        try await request(
            ReadingSubmissionListResponse.self,
            path: "v1/child/submissions",
            bearer: deviceCredential
        ).items
    }

    func childReadingSubmission(
        submissionID: String,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)",
            bearer: deviceCredential
        )
    }

    func childReadingMediaURL(
        mediaID: String,
        deviceCredential: String
    ) async throws -> MediaReadURLResponse {
        try await request(
            MediaReadURLResponse.self,
            path: "v1/child/media/\(mediaID)/read-url",
            bearer: deviceCredential
        )
    }

    func createReadingMediaUpload(
        submissionID: String,
        contentType: String,
        byteSize: Int,
        sha256: String,
        pageOrder: Int,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> MediaUploadIntentResponse {
        try await request(
            MediaUploadIntentResponse.self,
            path: "v1/child/submissions/\(submissionID)/media-uploads",
            method: "POST",
            bearer: deviceCredential,
            body: ReadingMediaUploadBody(
                contentType: contentType,
                byteSize: byteSize,
                sha256: sha256,
                pageOrder: pageOrder,
                expectedVersion: expectedVersion
            )
        )
    }

    func uploadReadingMedia(
        _ data: Data,
        intent: MediaUploadIntentResponse
    ) async throws {
        var request = URLRequest(url: intent.uploadUrl)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in intent.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.server(
                statusCode: http.statusCode,
                message: "Media upload failed (\(http.statusCode))."
            )
        }
    }

    func completeReadingMediaUpload(
        submissionID: String,
        uploadID: String,
        byteSize: Int,
        sha256: String,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)/media-uploads/\(uploadID)/complete",
            method: "POST",
            bearer: deviceCredential,
            body: CompleteReadingMediaUploadBody(
                byteSize: byteSize,
                sha256: sha256,
                expectedVersion: expectedVersion
            )
        )
    }

    func recordReadingOCR(
        submissionID: String,
        evidenceID: String,
        status: String,
        rawText: String,
        languageCodes: [String],
        ocrRevision: Int,
        visionRevision: Int,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)/evidence/\(evidenceID)/ocr",
            method: "PUT",
            bearer: deviceCredential,
            body: ReadingOCRBody(
                status: status,
                rawText: rawText,
                languageCodes: languageCodes,
                ocrRevision: ocrRevision,
                visionRevision: visionRevision,
                expectedVersion: expectedVersion
            )
        )
    }

    func removeReadingEvidence(
        submissionID: String,
        evidenceID: String,
        deviceCredential: String
    ) async throws {
        try await requestWithoutResponse(
            path: "v1/child/submissions/\(submissionID)/evidence/\(evidenceID)",
            method: "DELETE",
            bearer: deviceCredential
        )
    }

    func updateReadingTranscript(
        submissionID: String,
        correctedOCRText: String?,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)",
            method: "PATCH",
            bearer: deviceCredential,
            body: UpdateReadingTranscriptBody(
                expectedVersion: expectedVersion,
                correctedOcrText: correctedOCRText
            )
        )
    }

    func submitReadingSubmission(
        submissionID: String,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)/submit",
            method: "POST",
            bearer: deviceCredential,
            body: ReadingTransitionBody(expectedVersion: expectedVersion)
        )
    }

    func resubmitReadingSubmission(
        submissionID: String,
        expectedVersion: Int,
        deviceCredential: String
    ) async throws -> ReadingSubmissionResponse {
        try await request(
            ReadingSubmissionResponse.self,
            path: "v1/child/submissions/\(submissionID)/resubmit",
            method: "POST",
            bearer: deviceCredential,
            body: ReadingTransitionBody(expectedVersion: expectedVersion)
        )
    }

    func deleteReadingDraft(
        submissionID: String,
        deviceCredential: String
    ) async throws {
        try await requestWithoutResponse(
            path: "v1/child/submissions/\(submissionID)",
            method: "DELETE",
            bearer: deviceCredential
        )
    }

    func parentReadingSubmissions(
        childID: String,
        parentToken: String
    ) async throws -> [ReadingSubmissionResponse] {
        try await parentReadingSubmissionPage(
            childID: childID,
            limit: 100,
            parentToken: parentToken
        ).items
    }

    func parentReadingSubmissionPage(
        childID: String,
        cursor: String? = nil,
        limit: Int = 25,
        parentToken: String
    ) async throws -> ReadingSubmissionListResponse {
        guard var components = URLComponents(
            url: baseURL.appending(path: "v1/parent/submissions"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ClientError.invalidServerURL
        }
        components.queryItems = [
            URLQueryItem(name: "childId", value: childID),
            URLQueryItem(name: "limit", value: String(limit)),
            cursor.map { URLQueryItem(name: "cursor", value: $0) }
        ].compactMap { $0 }
        guard let url = components.url else {
            throw ClientError.invalidServerURL
        }
        return try await request(
            ReadingSubmissionListResponse.self,
            url: url,
            bearer: parentToken
        )
    }

    func parentReadingMediaURL(
        mediaID: String,
        parentToken: String
    ) async throws -> MediaReadURLResponse {
        try await request(
            MediaReadURLResponse.self,
            path: "v1/parent/media/\(mediaID)/read-url",
            bearer: parentToken
        )
    }

    func reviewReadingSubmission(
        submissionID: String,
        decision: String,
        comment: String?,
        rewardSeconds: Int,
        expectedVersion: Int,
        idempotencyKey: String,
        parentToken: String
    ) async throws -> ReadingReviewCommandResponse {
        try await request(
            ReadingReviewCommandResponse.self,
            path: "v1/parent/submissions/\(submissionID)/reviews",
            method: "POST",
            bearer: parentToken,
            body: ReadingReviewBody(
                decision: decision,
                comment: comment,
                rewardSeconds: rewardSeconds,
                expectedSubmissionVersion: expectedVersion,
                idempotencyKey: idempotencyKey
            )
        )
    }

    private func request<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        path: String,
        method: String = "GET",
        bearer: String? = nil
    ) async throws -> Response {
        try await request(
            responseType,
            path: path,
            method: method,
            bearer: bearer,
            encodedBody: nil
        )
    }

    private func request<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        url: URL,
        bearer: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(statusCode: http.statusCode, data: data)
        }
        guard let decoded = try? JSONDecoder.pagePass.decode(responseType, from: data) else {
            throw ClientError.invalidResponse
        }
        return decoded
    }

    private func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ responseType: Response.Type,
        path: String,
        method: String,
        bearer: String? = nil,
        body: Body
    ) async throws -> Response {
        try await request(
            responseType,
            path: path,
            method: method,
            bearer: bearer,
            encodedBody: try JSONEncoder.pagePass.encode(body)
        )
    }

    private func request<Response: Decodable & Sendable>(
        _ responseType: Response.Type,
        path: String,
        method: String,
        bearer: String?,
        encodedBody: Data?
    ) async throws -> Response {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let encodedBody {
            request.httpBody = encodedBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(statusCode: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder.pagePass.decode(responseType, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private func requestWithoutResponse(
        path: String,
        method: String,
        bearer: String? = nil
    ) async throws {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(statusCode: http.statusCode, data: data)
        }
    }

    private func responseError(statusCode: Int, data: Data) -> ClientError {
        if let envelope = try? JSONDecoder.pagePass.decode(
            APIErrorEnvelope.self,
            from: data
        ) {
            if statusCode == 401,
               ["device_revoked", "child_archived"].contains(envelope.error.code) {
                return .deviceRevoked(message: envelope.error.message)
            }
            return .server(
                statusCode: statusCode,
                message: envelope.error.message
            )
        }
        let message = try? JSONDecoder.pagePass.decode(
            BetterAuthErrorEnvelope.self,
            from: data
        ).message
        return .server(
            statusCode: statusCode,
            message: message ?? "Server error (\(statusCode))."
        )
    }
}

private struct EmptyBody: Codable, Sendable {}

private struct AppleSessionBody: Codable, Sendable {
    let challengeId: String
    let state: String
    let identityToken: String
    let displayName: String?
}

private struct BetterAuthSignUpBody: Codable, Sendable {
    let name: String
    let email: String
    let password: String
    let callbackURL: String
}

private struct UpdateFamilyPreferencesBody: Codable, Sendable {
    let expectedVersion: Int
    let defaultReadingRewardSeconds: Int
    let sessionPresetSeconds: [Int]
}

private struct UpdateParentPreferencesBody: Codable, Sendable {
    let readingRequestsEnabled: Bool
    let appRequestsEnabled: Bool
    let deviceAlertsEnabled: Bool
    let sessionEndedEnabled: Bool
}

private struct BetterAuthSignInBody: Codable, Sendable {
    let email: String
    let password: String
    let rememberMe: Bool
}

private struct BetterAuthVerificationBody: Codable, Sendable {
    let email: String
    let callbackURL: String
}

private struct BetterAuthPasswordResetRequestBody: Codable, Sendable {
    let email: String
    let redirectTo: String
}

private struct BetterAuthPasswordResetBody: Codable, Sendable {
    let newPassword: String
    let token: String
}

private struct BetterAuthErrorEnvelope: Codable, Sendable {
    let code: String?
    let message: String
}

private struct ClaimLocalDataBody: Codable, Sendable {
    let localParentToken: String
}

private struct CreditGrantBody: Codable, Sendable {
    let seconds: Int
    let reason: String
    let idempotencyKey: String
}

private struct ParentPushDeviceBody: Codable, Sendable {
    let installationId: String
    let token: String
    let environment: String
    let appVersion: String
    let appBuild: String

    init(installationId: String, token: String, environment: String) {
        self.installationId = installationId
        self.token = token
        self.environment = environment
        appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    }
}

private struct ChildPushDeviceBody: Codable, Sendable {
    let token: String
    let environment: String
    let appVersion: String
    let appBuild: String

    init(token: String, environment: String) {
        self.token = token
        self.environment = environment
        appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
    }
}

private struct PairingBody: Codable, Sendable {
    let installationId: String
    let deviceName: String
    let appVersion: String
    let appBuild: String
    let qrToken: String?
    let numericCode: String?

    init(
        installationId: String,
        deviceName: String,
        qrToken: String?,
        numericCode: String?
    ) {
        self.installationId = installationId
        self.deviceName = deviceName
        appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        self.qrToken = qrToken
        self.numericCode = numericCode
    }
}

private struct SettlementBody: Codable, Sendable {
    let localSessionId: String
    let requestedDurationSeconds: Int
    let balanceBeforeSeconds: Int
    let startedAt: Date
    let expiresAt: Date
    let endedAt: Date
    let consumedSeconds: Int
    let endReason: String
    let idempotencyKey: String

    init(settlement: EarnedTimeSettlement) {
        localSessionId = settlement.sessionID.uuidString.lowercased()
        requestedDurationSeconds = settlement.requestedDurationSeconds
        balanceBeforeSeconds = settlement.balanceBeforeSeconds
        startedAt = settlement.startedAt
        expiresAt = settlement.expiresAt
        endedAt = settlement.endedAt
        consumedSeconds = settlement.consumedSeconds
        endReason = settlement.endReason.rawValue
        idempotencyKey = settlement.idempotencyKey
    }
}

private struct EarnedTimeStartBody: Codable, Sendable {
    let requestedDurationSeconds: Int
    let balanceBeforeSeconds: Int
}

private struct ManagedAppRegistrationBody: Codable, Sendable {
    let apps: [ManagedAppRegistrationItem]
}

private struct AppRequestBody: Codable, Sendable {
    let managedAppId: String
    let message: String?
    let idempotencyKey: String
}

private struct AppRequestDecisionBody: Codable, Sendable {
    let policy: ManagedAppPolicyValue
    let expectedPolicyVersion: Int
    let expectedRequestVersion: Int
    let idempotencyKey: String
}

private struct AppPolicyUpdateBody: Codable, Sendable {
    let policy: ManagedAppPolicyValue
    let expectedPolicyVersion: Int
    let idempotencyKey: String
}

private struct PolicyAckBody: Codable, Sendable {
    let policyVersion: Int
    let result: String
    let appliedAt: Date
    let failureReason: String?
}

private struct CreateReadingSubmissionBody: Codable, Sendable {
    let bookTitle: String
    let author: String?
    let supersedesSubmissionId: String?
}

private struct ReadingMediaUploadBody: Codable, Sendable {
    let contentType: String
    let byteSize: Int
    let sha256: String
    let pageOrder: Int
    let expectedVersion: Int
}

private struct CompleteReadingMediaUploadBody: Codable, Sendable {
    let byteSize: Int
    let sha256: String
    let expectedVersion: Int
}

private struct ReadingOCRBody: Codable, Sendable {
    let status: String
    let rawText: String
    let languageCodes: [String]
    let ocrRevision: Int
    let visionRevision: Int
    let expectedVersion: Int
}

private struct UpdateReadingTranscriptBody: Encodable, Sendable {
    let expectedVersion: Int
    let correctedOcrText: String?

    private enum CodingKeys: String, CodingKey {
        case expectedVersion
        case correctedOcrText
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedVersion, forKey: .expectedVersion)
        if let correctedOcrText {
            try container.encode(correctedOcrText, forKey: .correctedOcrText)
        } else {
            try container.encodeNil(forKey: .correctedOcrText)
        }
    }
}

private struct ReadingTransitionBody: Codable, Sendable {
    let expectedVersion: Int
}

private struct ReadingReviewBody: Codable, Sendable {
    let decision: String
    let comment: String?
    let rewardSeconds: Int
    let expectedSubmissionVersion: Int
    let idempotencyKey: String
}

private extension JSONEncoder {
    static var pagePass: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

private extension JSONDecoder {
    static var pagePass: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class PagePassRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private extension URLSession {
    static let pagePass = URLSession(
        configuration: .ephemeral,
        delegate: PagePassRedirectDelegate(),
        delegateQueue: nil
    )
}
