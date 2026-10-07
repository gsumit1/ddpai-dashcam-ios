// MockHTTPControlClient — test-support / in-memory implementation
//
// Task 5.5: a programmable, dependency-free `HTTPControlClient` for driving
// subsystem and integration tests deterministically — no `URLSession`, no
// network. Lives in the MAIN library target (not Tests/) so it builds with
// `swift build`.
//
// Programmability (per the task):
//   • Canned responses: configure a default response, or a per-request response
//     keyed by the request's URL (optionally method), so a subsystem that issues
//     several distinct requests gets the right answer for each.
//   • Injectable failures: configure an error to throw instead of returning a
//     response (globally or per request).
//   • Injectable delays: configure how long `send` waits before producing its
//     result, so tests can exercise timeout bounds (R1.2, R1.5). The delay is a
//     real `Task.sleep` honoring cooperative cancellation, so a caller that
//     races `send` against its own timeout observes a `CancellationError` when
//     it cancels — exactly as the production client does.
//
// Download: `download(_:to:resumingFrom:)` returns a fully scripted
// `AsyncThrowingStream` of `DownloadProgress`, with an optional per-emission
// delay and an optional terminal error, so resumable-download timing and
// interruption paths can be driven without any real file transfer. When a byte
// plan is scripted, the mock also writes placeholder bytes to `fileURL` so
// callers that inspect the partial file see the expected size.
//
// Thread-safety: mutable programmable state is guarded by a lock; the type is
// `Sendable`.

import Foundation

/// A programmable, in-memory `HTTPControlClient` for tests.
public final class MockHTTPControlClient: HTTPControlClient, @unchecked Sendable {

    // MARK: Canned send outcomes

    /// What a matched `send` should do.
    public enum SendOutcome: Sendable {
        /// Return this response (after any configured delay).
        case respond(HTTPResponse)
        /// Throw this error (after any configured delay).
        case fail(Error)
    }

    /// A matcher + outcome + optional delay for a single `send` rule. Rules are
    /// evaluated in insertion order; the first match wins.
    private struct SendRule {
        let matches: @Sendable (HTTPRequest) -> Bool
        let outcome: SendOutcome
        let delay: Duration
    }

    // MARK: Download scripting

    /// A scripted download: a sequence of progress emissions, an optional
    /// per-step delay, and an optional terminal error to simulate interruption.
    public struct DownloadScript: Sendable {
        /// Progress values to emit, in order.
        public var progress: [DownloadProgress]
        /// Delay inserted before each emission (to pace/throttle, exercise timing).
        public var stepDelay: Duration
        /// If set, the stream finishes by throwing this error after emitting the
        /// progress values (simulates mid-transfer interruption, R5.5).
        public var terminalError: Error?
        /// When true, placeholder bytes are written to the destination file up to
        /// the last emission's `completedBytes`, so a caller can inspect partial
        /// file size without a real transfer.
        public var writesPlaceholderBytes: Bool

        public init(
            progress: [DownloadProgress],
            stepDelay: Duration = .zero,
            terminalError: Error? = nil,
            writesPlaceholderBytes: Bool = false
        ) {
            self.progress = progress
            self.stepDelay = stepDelay
            self.terminalError = terminalError
            self.writesPlaceholderBytes = writesPlaceholderBytes
        }
    }

    // MARK: State

    private let lock = NSLock()

    private var _sendRules: [SendRule] = []
    private var _defaultOutcome: SendOutcome?
    private var _defaultDelay: Duration = .zero
    private var _downloadScript: DownloadScript?
    private var _sentRequests: [HTTPRequest] = []
    private var _downloadRequests: [(request: HTTPRequest, fileURL: URL, resumingFrom: Int64)] = []

    public init() {}

    // MARK: - Configuration (programmable)

    /// Sets the fallback response used when no per-request rule matches.
    @discardableResult
    public func stubDefaultResponse(_ response: HTTPResponse, delay: Duration = .zero) -> Self {
        withLock {
            _defaultOutcome = .respond(response)
            _defaultDelay = delay
        }
        return self
    }

    /// Sets a fallback error thrown when no per-request rule matches.
    @discardableResult
    public func stubDefaultError(_ error: Error, delay: Duration = .zero) -> Self {
        withLock {
            _defaultOutcome = .fail(error)
            _defaultDelay = delay
        }
        return self
    }

    /// Adds a response rule matched by exact URL (and optional method).
    @discardableResult
    public func stub(
        url: URL,
        method: HTTPMethod? = nil,
        response: HTTPResponse,
        delay: Duration = .zero
    ) -> Self {
        addRule(matching: { req in
            req.url == url && (method == nil || req.method == method)
        }, outcome: .respond(response), delay: delay)
    }

    /// Adds an error rule matched by exact URL (and optional method).
    @discardableResult
    public func stub(
        url: URL,
        method: HTTPMethod? = nil,
        error: Error,
        delay: Duration = .zero
    ) -> Self {
        addRule(matching: { req in
            req.url == url && (method == nil || req.method == method)
        }, outcome: .fail(error), delay: delay)
    }

    /// Adds a rule matched by a custom predicate (e.g. inspect headers/path).
    @discardableResult
    public func stub(
        where predicate: @escaping @Sendable (HTTPRequest) -> Bool,
        outcome: SendOutcome,
        delay: Duration = .zero
    ) -> Self {
        addRule(matching: predicate, outcome: outcome, delay: delay)
    }

    /// Scripts the behavior of `download(_:to:resumingFrom:)`.
    @discardableResult
    public func stubDownload(_ script: DownloadScript) -> Self {
        withLock { _downloadScript = script }
        return self
    }

    // MARK: - Recorded calls (assertions)

    public var sentRequests: [HTTPRequest] { withLock { _sentRequests } }
    public var downloadRequests: [(request: HTTPRequest, fileURL: URL, resumingFrom: Int64)] {
        withLock { _downloadRequests }
    }

    // MARK: - HTTPControlClient

    public func send(_ request: HTTPRequest, timeout: Duration) async throws -> HTTPResponse {
        let (outcome, delay): (SendOutcome, Duration) = withLock {
            _sentRequests.append(request)
            if let rule = _sendRules.first(where: { $0.matches(request) }) {
                return (rule.outcome, rule.delay)
            }
            if let fallback = _defaultOutcome {
                return (fallback, _defaultDelay)
            }
            // No stub: surface loudly rather than silently returning a default.
            return (.fail(MockHTTPError.notStubbed(request.url)), .zero)
        }

        if delay > .zero {
            // Honors cooperative cancellation: a caller racing this against its
            // own timeout observes CancellationError on cancel (R1.2, R1.5).
            try await Task.sleep(for: delay)
        }

        switch outcome {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }

    public func download(
        _ request: HTTPRequest,
        to fileURL: URL,
        resumingFrom byte: Int64
    ) -> AsyncThrowingStream<DownloadProgress, Error> {
        let script: DownloadScript? = withLock {
            _downloadRequests.append((request, fileURL, byte))
            return _downloadScript
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let script else {
                    continuation.finish(throwing: MockHTTPError.notStubbed(request.url))
                    return
                }
                do {
                    for progress in script.progress {
                        try Task.checkCancellation()
                        if script.stepDelay > .zero {
                            try await Task.sleep(for: script.stepDelay)
                        }
                        if script.writesPlaceholderBytes {
                            Self.writePlaceholder(to: fileURL, bytes: progress.completedBytes)
                        }
                        continuation.yield(progress)
                    }
                    if let terminalError = script.terminalError {
                        continuation.finish(throwing: terminalError)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    // Cancellation or a sleep failure terminates the stream.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    @discardableResult
    private func addRule(
        matching predicate: @escaping @Sendable (HTTPRequest) -> Bool,
        outcome: SendOutcome,
        delay: Duration
    ) -> Self {
        withLock { _sendRules.append(SendRule(matches: predicate, outcome: outcome, delay: delay)) }
        return self
    }

    /// Writes `bytes` placeholder zero bytes to `fileURL` so a caller inspecting
    /// a partial download sees the expected size. Best-effort; failures are
    /// ignored since this is a test convenience, not the subject under test.
    private static func writePlaceholder(to fileURL: URL, bytes: Int64) {
        guard bytes >= 0 else { return }
        let count = Int(clamping: bytes)
        let data = Data(count: count)
        try? data.write(to: fileURL)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Errors raised by `MockHTTPControlClient` when a request is not stubbed.
public enum MockHTTPError: Error, Equatable {
    /// `send`/`download` was called for a URL with no matching stub.
    case notStubbed(URL)
}
