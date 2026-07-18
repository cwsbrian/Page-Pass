import FamilyControls

struct AuthorizationService {
    func requestChildAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .child)
    }

    func requestIndividualAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }

    func revokeAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            AuthorizationCenter.shared.revokeAuthorization { result in
                continuation.resume(with: result)
            }
        }
    }
}
