import Foundation
import PagePassCore

struct PagePassAPIClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidServerURL
        case invalidResponse
        case server(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL:
                "Enter a valid PagePass server URL."
            case .invalidResponse:
                "The PagePass server returned an invalid response."
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

    func createChild(name: String, parentToken: String) async throws -> ChildSummary {
        try await request(
            ChildSummary.self,
            path: "v1/parent/children",
            method: "POST",
            bearer: parentToken,
            body: ["name": name]
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

    func grantCredit(
        childID: String,
        seconds: Int,
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
                reason: "parent_test_grant",
                idempotencyKey: idempotencyKey
            )
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
            let envelope = try? JSONDecoder.pagePass.decode(APIErrorEnvelope.self, from: data)
            throw ClientError.server(
                statusCode: http.statusCode,
                message: envelope?.error.message ?? "Server error (\(http.statusCode))."
            )
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
            let envelope = try? JSONDecoder.pagePass.decode(APIErrorEnvelope.self, from: data)
            throw ClientError.server(
                statusCode: http.statusCode,
                message: envelope?.error.message ?? "Server error (\(http.statusCode))."
            )
        }
    }
}

private struct EmptyBody: Codable, Sendable {}

private struct AppleSessionBody: Codable, Sendable {
    let challengeId: String
    let state: String
    let identityToken: String
    let displayName: String?
}

private struct ClaimLocalDataBody: Codable, Sendable {
    let localParentToken: String
}

private struct CreditGrantBody: Codable, Sendable {
    let seconds: Int
    let reason: String
    let idempotencyKey: String
}

private struct PairingBody: Codable, Sendable {
    let installationId: String
    let deviceName: String
    let qrToken: String?
    let numericCode: String?
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
