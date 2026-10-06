import Foundation
import GRDB

/// Merge rule: while a thread has a queued or in-flight action, incoming history is
/// applied underneath it and the local optimistic state is shown until it completes.
enum PendingOverlay {
    static func reapply(_ db: Database, accountID: String, threadIDs: Set<String>) throws {
        // Implemented with the action queue (M5).
    }
}
