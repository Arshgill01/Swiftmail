import AppKit
import Network
import SwiftmailCore

/// Sync triggers from the system: app activation, sleep and wake, and the network coming back.
@MainActor
final class SyncTriggers {
    private let sessions: @MainActor () async -> [AccountSession]
    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()
    private var wasOnline = true

    init(sessions: @escaping @MainActor () async -> [AccountSession]) {
        self.sessions = sessions
    }

    func start() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forEach { await $0.setAppActive(true) } }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forEach { await $0.setAppActive(false) } }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forEach { await $0.pause() } }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forEach { await $0.resume() } }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "app.swiftmail.path"))
    }

    private func networkChanged(online: Bool) {
        defer { wasOnline = online }
        if online, !wasOnline {
            forEach { await $0.triggerSync() }
        }
    }

    func syncAll() {
        forEach { await $0.triggerSync() }
    }

    private func forEach(_ body: @escaping @Sendable (AccountSession) async -> Void) {
        Task {
            for session in await sessions() {
                await body(session)
            }
        }
    }
}
