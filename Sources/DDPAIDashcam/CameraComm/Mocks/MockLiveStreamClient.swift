// MockLiveStreamClient — test-support / in-memory implementation
//
// Task 5.5: a programmable, dependency-free `LiveStreamClient` for driving
// Live_Preview tests deterministically — no AVFoundation, no RTSP, no network.
// Lives in the MAIN library target (not Tests/) so it builds with `swift build`.
//
// Programmability (per the task):
//   • Start outcome: return a canned `LiveStreamHandle`, or throw a canned
//     error, after an injectable delay (so first-frame / open-timeout bounds can
//     be exercised, R2.2/R2.7).
//   • Frames: a test pushes `DecodedFrame`s into the `frames` stream on demand
//     via `emit(_:)`, or pre-loads a script via `enqueueFrames(_:)`; this models
//     the camera delivering decoded frames while rendering (R2.1, R2.3).
//   • Audio: `audioAvailable` is programmable to drive the mute-control path
//     (R2.6); `setAudioMuted` is recorded so a test can assert it.
//
// `start` honors cooperative cancellation during its delay, matching how a real
// client maps a caller-imposed timeout to task cancellation.
//
// Thread-safety: mutable state is guarded by a lock; the type is `Sendable`.

import Foundation

/// A programmable, in-memory `LiveStreamClient` for tests.
public final class MockLiveStreamClient: LiveStreamClient, @unchecked Sendable {

    // MARK: Start outcome

    /// What `start(url:)` should do.
    public enum StartOutcome: Sendable {
        case success(LiveStreamHandle)
        case failure(Error)
    }

    // MARK: State

    private let lock = NSLock()

    private var _startOutcome: StartOutcome
    private var _startDelay: Duration = .zero
    private var _audioAvailable: Bool
    private var _muted: Bool = false

    // Call recording for assertions.
    private var _startedURLs: [URL] = []
    private var _stoppedHandles: [LiveStreamHandle] = []
    private var _muteCalls: [Bool] = []

    // Frame delivery: a single continuation feeds the public `frames` stream.
    private let _frames: AsyncStream<DecodedFrame>
    private let _framesContinuation: AsyncStream<DecodedFrame>.Continuation

    // MARK: Init

    /// Creates a live-stream mock.
    ///
    /// - Parameters:
    ///   - startHandle: handle returned by a successful `start` (default id).
    ///   - audioAvailable: initial value reported by `audioAvailable` (R2.6).
    public init(
        startHandle: LiveStreamHandle = LiveStreamHandle(id: "mock-live-session"),
        audioAvailable: Bool = false
    ) {
        self._startOutcome = .success(startHandle)
        self._audioAvailable = audioAvailable
        var continuation: AsyncStream<DecodedFrame>.Continuation!
        self._frames = AsyncStream<DecodedFrame> { continuation = $0 }
        self._framesContinuation = continuation
    }

    deinit {
        _framesContinuation.finish()
    }

    // MARK: - Configuration (programmable)

    /// Programs `start(url:)` to succeed with the given handle.
    @discardableResult
    public func stubStartSuccess(_ handle: LiveStreamHandle = LiveStreamHandle(id: "mock-live-session"), delay: Duration = .zero) -> Self {
        withLock {
            _startOutcome = .success(handle)
            _startDelay = delay
        }
        return self
    }

    /// Programs `start(url:)` to throw the given error.
    @discardableResult
    public func stubStartFailure(_ error: Error, delay: Duration = .zero) -> Self {
        withLock {
            _startOutcome = .failure(error)
            _startDelay = delay
        }
        return self
    }

    /// Sets whether the stream reports an audio track (R2.6).
    @discardableResult
    public func setAudioAvailable(_ available: Bool) -> Self {
        withLock { _audioAvailable = available }
        return self
    }

    // MARK: - Frame delivery (programmable)

    /// Pushes a single decoded frame to the `frames` stream.
    public func emit(_ frame: DecodedFrame) {
        _framesContinuation.yield(frame)
    }

    /// Pushes a sequence of decoded frames to the `frames` stream, in order.
    public func enqueueFrames(_ frames: [DecodedFrame]) {
        for frame in frames { _framesContinuation.yield(frame) }
    }

    /// Finishes the `frames` stream (no more frames will arrive).
    public func finishFrames() {
        _framesContinuation.finish()
    }

    // MARK: - Recorded calls (assertions)

    public var startedURLs: [URL] { withLock { _startedURLs } }
    public var stoppedHandles: [LiveStreamHandle] { withLock { _stoppedHandles } }
    public var muteCalls: [Bool] { withLock { _muteCalls } }
    /// The most recent muted state requested via `setAudioMuted`.
    public var isMuted: Bool { withLock { _muted } }

    // MARK: - LiveStreamClient

    public func start(url: URL) async throws -> LiveStreamHandle {
        let (outcome, delay): (StartOutcome, Duration) = withLock {
            _startedURLs.append(url)
            return (_startOutcome, _startDelay)
        }
        if delay > .zero {
            // Honors cancellation so an open-timeout race surfaces CancellationError.
            try await Task.sleep(for: delay)
        }
        switch outcome {
        case .success(let handle): return handle
        case .failure(let error): throw error
        }
    }

    public func stop(_ handle: LiveStreamHandle) async {
        withLock { _stoppedHandles.append(handle) }
    }

    public var frames: AsyncStream<DecodedFrame> { _frames }

    public var audioAvailable: Bool { withLock { _audioAvailable } }

    public func setAudioMuted(_ muted: Bool) {
        withLock {
            _muted = muted
            _muteCalls.append(muted)
        }
    }

    // MARK: - Private

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
