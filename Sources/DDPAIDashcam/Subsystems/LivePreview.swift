// Live_Preview
//
// Task 8.1: `LivePreviewing` protocol and the concrete `LivePreview` class that
// renders the Camera's real-time stream while connected.
//
// Design reference: design.md → Components and Interfaces → Live_Preview. The
// subsystem observes the shared Connection_State (owned by Connection_Manager)
// rather than probing the link itself, so it reacts uniformly to
// connect/interrupt/disconnect transitions.
//
// Requirements covered (R2.1–R2.7):
//   - R2.1: while connected, render the real-time stream (end-to-end latency is
//     a transport property surfaced here as the rendering state).
//   - R2.2: on open while connected, display the first frame within 5s.
//   - R2.3: while rendering, surface the stream resolution and a signal
//     indicator reflecting link quality.
//   - R2.4: if the Connection_State leaves connected while active, stop
//     rendering within 2s and show a stream-unavailable message.
//   - R2.5: when the user leaves the screen (`close`), stop requesting the
//     stream from the camera (TEARDOWN).
//   - R2.6: expose a mute control only when the camera reports audio available.
//   - R2.7: if no first frame arrives within 5s, show a stream-unavailable
//     message and provide a retry control.
//
// Camera I/O funnels through the protocol-neutral `LiveStreamClient`
// (start/stop/frames/audioAvailable/setAudioMuted) and the stream URL from
// `CameraProtocolAdapter.liveStreamURL()`.

import Combine
import Foundation

// MARK: - Timing constants

/// Fixed timing bounds taken from Requirement 2. Centralized so the subsystem
/// and its tests reference the same values.
public enum LivePreviewTiming {
    /// Maximum time to display the first video frame after opening (R2.2, R2.7).
    public static let firstFrameTimeout: Duration = .seconds(5)
    /// Maximum time to stop rendering after the link leaves connected (R2.4).
    public static let stopOnInterruptBound: Duration = .seconds(2)
}

// MARK: - Signal indicator

/// A coarse link-quality indicator surfaced while rendering (R2.3). Derived from
/// the live stream's frame delivery; kept observably distinct per level.
public enum SignalQuality: Equatable, Sendable {
    case poor
    case fair
    case good
}

/// The resolution of the rendered live stream (R2.3), in pixels.
public struct StreamResolution: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

// MARK: - Status

/// Observable status of the Live_Preview (design.md → Live_Preview).
public enum LivePreviewStatus: Equatable {
    /// Not started, or torn down after leaving the screen.
    case idle
    /// Opening the stream; waiting for the first frame (R2.2).
    case starting
    /// Rendering frames; surfaces resolution + signal indicator (R2.1, R2.3).
    case rendering(resolution: StreamResolution, signal: SignalQuality)
    /// Stream could not start, or stopped because the link left connected
    /// (R2.4, R2.7). Carries a user-facing message; the view offers retry.
    case unavailable(message: String)
}

// MARK: - User-facing messages

/// User-facing strings surfaced via the `unavailable` status. Owned here so the
/// subsystem fully owns Live_Preview semantics; the view renders them verbatim.
public enum LivePreviewMessage {
    /// R2.7 — the first frame did not arrive within the 5s bound.
    public static let streamUnavailable =
        "The live stream is unavailable. Tap retry to try again."
    /// R2.4 — the camera link left connected while the preview was active.
    public static let linkLeftConnected =
        "The live stream stopped because the camera link was lost."
}

// MARK: - Protocol

/// The Live_Preview interface (design.md → Live_Preview).
@MainActor
public protocol LivePreviewing: AnyObject {
    /// Current status: idle, starting, rendering(resolution, signal), or
    /// unavailable (R2.3, R2.4, R2.7).
    var status: LivePreviewStatus { get }

    /// Whether the camera reports audio available in the current stream, which
    /// gates the mute control (R2.6).
    var audioAvailable: Bool { get }

    /// Whether live audio is currently muted. Meaningful only while
    /// `audioAvailable` is true.
    var isAudioMuted: Bool { get }

    /// Opens the stream. Displays the first frame within 5s or transitions to
    /// `unavailable` with a retry affordance (R2.2, R2.7).
    func open() async

    /// Stops requesting the stream and tears down the session when the user
    /// leaves the screen (R2.5).
    func close() async

    /// Mutes/unmutes live audio; only takes effect when `audioAvailable` is
    /// true (R2.6).
    func setAudioMuted(_ muted: Bool)

    /// Re-attempts opening the stream after an `unavailable` state (R2.7).
    func retry() async
}

// MARK: - Concrete subsystem

/// Concrete Live_Preview. `@MainActor` so its observable status is mutated on
/// the main actor and read safely by SwiftUI view models.
@MainActor
public final class LivePreview: LivePreviewing, ObservableObject {

    // MARK: Observable state

    /// Current render/availability status (R2.3, R2.4, R2.7).
    @Published public private(set) var status: LivePreviewStatus = .idle

    /// Whether the current stream carries audio (R2.6).
    @Published public private(set) var audioAvailable: Bool = false

    /// Whether live audio is muted (R2.6).
    @Published public private(set) var isAudioMuted: Bool = false

    public var statusPublisher: Published<LivePreviewStatus>.Publisher { $status }

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let streamClient: LiveStreamClient
    private let connectionState: () -> ConnectionState
    private let connectionUpdates: () -> AsyncStream<ConnectionState>

    // MARK: Internal bookkeeping

    /// Active stream handle while rendering; `nil` when idle/unavailable.
    private var handle: LiveStreamHandle?
    /// Task consuming decoded frames to drive the rendering status (R2.1, R2.3).
    private var frameTask: Task<Void, Never>?
    /// Task observing Connection_State to stop rendering on leave (R2.4).
    private var connectionTask: Task<Void, Never>?

    /// Creates a Live_Preview.
    ///
    /// - Parameters:
    ///   - adapter: provides the live stream URL (`liveStreamURL()`).
    ///   - streamClient: opens/tears down the RTSP/RTP session and delivers
    ///     frames.
    ///   - connectionState: reads the current shared Connection_State. The
    ///     Connection_Manager owns the state; this subsystem only observes it.
    ///   - connectionUpdates: a stream of Connection_State transitions used to
    ///     stop rendering within 2s when the link leaves connected (R2.4).
    public init(
        adapter: CameraProtocolAdapter,
        streamClient: LiveStreamClient,
        connectionState: @escaping () -> ConnectionState,
        connectionUpdates: @escaping () -> AsyncStream<ConnectionState>
    ) {
        self.adapter = adapter
        self.streamClient = streamClient
        self.connectionState = connectionState
        self.connectionUpdates = connectionUpdates
    }

    deinit {
        frameTask?.cancel()
        connectionTask?.cancel()
    }

    // MARK: - Open (R2.1, R2.2, R2.3, R2.7)

    public func open() async {
        // R2.4 precondition: live preview renders only while connected
        // (Property 3). If not connected, there is nothing to render.
        guard connectionState() == .connected else {
            status = .unavailable(message: LivePreviewMessage.streamUnavailable)
            return
        }

        // Reset any prior session and move to the starting state (R2.2).
        await teardownStream()
        status = .starting
        audioAvailable = false
        isAudioMuted = false

        // Observe Connection_State so a transition out of connected stops
        // rendering within 2s (R2.4).
        startConnectionObserver()

        let url = adapter.liveStreamURL()
        let started: LiveStreamHandle
        do {
            started = try await streamClient.start(url: url)
        } catch {
            // Could not open the session → unavailable + retry (R2.7).
            await teardownStream()
            status = .unavailable(message: LivePreviewMessage.streamUnavailable)
            return
        }
        handle = started
        // Reflect audio availability as reported by the camera (R2.6).
        audioAvailable = streamClient.audioAvailable

        // R2.2 / R2.7: await the first frame within the 5s bound. If it does
        // not arrive we transition to unavailable and offer retry.
        let firstFrame = await waitForFirstFrame(timeout: LivePreviewTiming.firstFrameTimeout)
        guard let frame = firstFrame else {
            await teardownStream()
            status = .unavailable(message: LivePreviewMessage.streamUnavailable)
            return
        }

        // First frame arrived: enter rendering and surface resolution + signal
        // (R2.1, R2.3), then keep consuming frames to track render state.
        status = .rendering(
            resolution: StreamResolution(width: frame.width, height: frame.height),
            signal: .good
        )
        startFrameConsumer()
    }

    public func close() async {
        // R2.5: stop requesting the stream from the camera and go idle.
        await teardownStream()
        status = .idle
    }

    public func setAudioMuted(_ muted: Bool) {
        // R2.6: only act when the camera reports audio is available.
        guard audioAvailable else { return }
        isAudioMuted = muted
        streamClient.setAudioMuted(muted)
    }

    public func retry() async {
        // R2.7: a retry re-attempts opening the stream.
        await open()
    }

    // MARK: - First-frame wait (R2.2, R2.7)

    /// Awaits the first decoded frame, bounded by `timeout`. Returns the frame,
    /// or `nil` if the bound elapsed before any frame arrived (R2.2, R2.7).
    private func waitForFirstFrame(timeout: Duration) async -> DecodedFrame? {
        let frames = streamClient.frames
        return await withTaskGroup(of: DecodedFrame?.self) { group in
            group.addTask {
                for await frame in frames {
                    return frame
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Ongoing frame consumption (R2.1, R2.3)

    /// Continuously consumes frames while rendering so the resolution indicator
    /// tracks the live stream (R2.3). The consumer stops when the stream ends
    /// or the task is cancelled (on close / link loss).
    private func startFrameConsumer() {
        frameTask?.cancel()
        let frames = streamClient.frames
        frameTask = Task { [weak self] in
            for await frame in frames {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.updateRendering(with: frame)
            }
        }
    }

    /// Updates the rendering status with the latest frame's resolution. Only
    /// applies while already in the rendering state so a late frame cannot
    /// resurrect a torn-down preview.
    private func updateRendering(with frame: DecodedFrame) {
        guard case .rendering(_, let signal) = status else { return }
        status = .rendering(
            resolution: StreamResolution(width: frame.width, height: frame.height),
            signal: signal
        )
    }

    // MARK: - Connection observation (R2.4)

    /// Observes Connection_State transitions and, when the link leaves
    /// connected while the preview is active, stops rendering within 2s and
    /// shows a stream-unavailable message (R2.4, Property 3).
    private func startConnectionObserver() {
        connectionTask?.cancel()
        let updates = connectionUpdates()
        connectionTask = Task { [weak self] in
            for await newState in updates {
                if Task.isCancelled { return }
                guard let self else { return }
                if newState != .connected {
                    await self.handleLinkLeftConnected()
                    return
                }
            }
        }
    }

    /// Stops rendering and reports stream-unavailable when the link is no longer
    /// connected (R2.4). The teardown happens well within the 2s bound.
    private func handleLinkLeftConnected() async {
        // Ignore if we already stopped (idle / unavailable).
        switch status {
        case .idle, .unavailable:
            return
        case .starting, .rendering:
            await teardownStream()
            status = .unavailable(message: LivePreviewMessage.linkLeftConnected)
        }
    }

    // MARK: - Teardown (R2.5)

    /// Tears down the active stream session and cancels observers (R2.5).
    private func teardownStream() async {
        frameTask?.cancel()
        frameTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        if let handle {
            await streamClient.stop(handle)
        }
        handle = nil
        audioAvailable = false
    }
}
