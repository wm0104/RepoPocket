import SwiftUI

/// Shared UI rules for consistent interaction behaviour across views.
enum UIRules {
    /// Apply a state change with animations disabled, so a refresh or
    /// re-render never flickers. Replaces the three-line Transaction recipe.
    static func withoutAnimation<Result>(_ body: () throws -> Result) rethrows -> Result {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return try withTransaction(transaction, body)
    }
}
