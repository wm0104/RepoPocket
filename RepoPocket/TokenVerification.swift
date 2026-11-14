import Foundation

/// Submits a pasted Token without losing the user's text: the caller only clears the field
/// after success, and a first attempt dropped by the system cellular-permission prompt (or a
/// flaky link) is retried once automatically.
enum TokenVerification {
    static func submit(_ credential: String,
                       attempt: (String) async throws -> Void) async throws {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError(text: "请先粘贴 Token")
        }
        do {
            try await attempt(credential)
        } catch {
            guard RefreshFailure.isTransient(error) else { throw error }
            try await attempt(credential)
        }
    }
}
