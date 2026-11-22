import Foundation

/// A value guarded by a lock, for state shared between threads and tasks.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    public func with<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A wait that ran out of time.
public struct TimedOut: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String = "Timed out") { self.message = message }
    public var errorDescription: String? { message }
}

/// Sleeps for `seconds`; throws `CancellationError` when the task is cancelled.
public func pause(_ seconds: Double) async throws {
    guard seconds > 0 else { return try Task.checkCancellation() }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Runs `body`, cancelling it and throwing `TimedOut` after `seconds`. `body` must stop when
/// cancelled, since the call returns only once it has.
public func withTimeout<T: Sendable>(_ seconds: Double, message: String = "Timed out", _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await pause(seconds)
            throw TimedOut(message)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimedOut(message) }
        return first
    }
}

/// Checks `check` every `interval` seconds until it returns a value, or returns nil after `timeout`.
public func poll<T>(timeout: Double, every interval: Double = 0.1, _ check: () async throws -> T?) async throws -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let v = try await check() { return v }
        if Date() >= deadline { return nil }
        try await pause(min(interval, max(0.01, deadline.timeIntervalSinceNow)))
    }
}

/// Resumes a continuation once, whichever of the callback, the time-out or cancellation comes first.
public final class Resumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    fileprivate init() {}

    fileprivate func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let r = early {
            early = nil
            lock.unlock()
            c.resume(with: r)
            return
        }
        continuation = c
        lock.unlock()
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    public func resume(_ result: Result<T, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
    }

    public func succeed(_ value: T) { resume(.success(value)) }
    public func fail(_ error: Error) { resume(.failure(error)) }
}

/// Bridges a callback API to async. `start` gets a `Resumer` to complete; the call throws
/// `TimedOut` after `timeout` seconds and `CancellationError` when cancelled, calling `onEnd` then.
public func bridge<T>(
    timeout: Double? = nil,
    timeoutMessage: String = "Timed out",
    onEnd: @escaping @Sendable () -> Void = {},
    _ start: (Resumer<T>) -> Void
) async throws -> T {
    let r = Resumer<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            r.attach(c)
            if let t = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + t) {
                    if !r.isFinished {
                        r.fail(TimedOut(timeoutMessage))
                        onEnd()
                    }
                }
            }
            start(r)
        }
    } onCancel: {
        if !r.isFinished {
            r.fail(CancellationError())
            onEnd()
        }
    }
}

/// A short random id of letters and digits.
public func randomId(_ length: Int = 12) -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
}
