//
//  ConnectivityMonitor.swift
//  Binged
//
//  "The network came back."
//
//  The outbox's other three triggers are all things the *user* does — signing
//  in, foregrounding the app, finishing a ranking. This is the one that fires
//  when nothing has happened at all: a title ranked on a train publishes when
//  the tunnel ends, rather than waiting for the next launch.
//
//  Behind a protocol like every other outside-the-app dependency, so tests
//  drive reconnection as a function call instead of by unplugging something.
//

import Foundation
import Network

// MARK: - ConnectivityMonitor

protocol ConnectivityMonitor: AnyObject, Sendable {

    /// Starts watching. `onReconnect` fires on the **transition** from offline
    /// to online, not on every path update and not for the state at start-up.
    ///
    /// The distinction matters: `NWPathMonitor` reports the current path
    /// immediately, so firing on every satisfied path would drain once at
    /// launch on top of the launch drain, and again on every unrelated
    /// interface change.
    func start(onReconnect: @escaping @Sendable () -> Void)

    func stop()
}

// MARK: - NetworkConnectivityMonitor

final class NetworkConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.watchrank.connectivity")
    private let lock = NSLock()

    /// `nil` until the first path arrives, so the first update establishes the
    /// baseline rather than counting as a change.
    private var wasSatisfied: Bool?
    private var isRunning = false

    init() {}

    deinit { monitor.cancel() }

    func start(onReconnect: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied

            lock.lock()
            let previous = wasSatisfied
            wasSatisfied = satisfied
            lock.unlock()

            // Offline → online only. `nil` is the baseline reading.
            if previous == false, satisfied { onReconnect() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
        monitor.cancel()
    }
}

// MARK: - MockConnectivityMonitor

/// Reconnection as a method call.
final class MockConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private(set) var isRunning = false

    init() {}

    func start(onReconnect: @escaping @Sendable () -> Void) {
        lock.lock(); handler = onReconnect; isRunning = true; lock.unlock()
    }

    func stop() {
        lock.lock(); handler = nil; isRunning = false; lock.unlock()
    }

    /// Simulates the network returning.
    func reconnect() {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }
}
