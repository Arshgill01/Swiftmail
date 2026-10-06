import Foundation
import SwiftmailCore

/// The on-screen toast with an optional Undo, shown for 8 seconds.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

/// Remembers recent actions so Command-Z, `z` and the toast can undo them.
@MainActor
@Observable
final class UndoCenter {
    private(set) var toast: Toast?
    @ObservationIgnored private var stack: [[UndoRecord]] = []
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    static let toastDuration: Duration = .seconds(8)
    static let maxDepth = 20

    var canUndo: Bool {
        !stack.isEmpty
    }

    func push(_ records: [UndoRecord]) {
        guard let first = records.first else { return }
        stack.append(records)
        if stack.count > Self.maxDepth {
            stack.removeFirst()
        }
        show(Toast(message: first.title, canUndo: true))
    }

    func show(_ toast: Toast) {
        self.toast = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismiss() {
        toast = nil
    }

    /// Takes the most recent action off the stack.
    func popLast() -> [UndoRecord]? {
        stack.popLast()
    }
}
