// AVFoundationLiveStreamClient
//
// Task 5.4: the concrete `LiveStreamClient` for Live_Preview. It owns the
// RTSP/RTP session lifecycle (DESCRIBE → SETUP → PLAY → PAUSE → TEARDOWN) and
// exposes decoded H.264 frames via `AsyncStream<DecodedFrame>`, plus
// `audioAvailable` and `setAudioMuted` per the protocol in `Protocols.swift`.
//
// Design reference: design.md → "Camera Communication Model" → Media channel:
// Live_Preview is modeled as an RTSP-style control session carrying H.264 video
// and optional audio over RTP (R2.1, R2.5, R2.6).
//
// ─────────────────────────────────────────────────────────────────────────
// WHY THIS IS STRUCTURED AROUND AN INJECTABLE TRANSPORT SEAM
// ─────────────────────────────────────────────────────────────────────────
// AVFoundation's `AVPlayer` does NOT natively support the `rtsp://` scheme, and
// a full RTSP/RTP depacketizer + H.264 decoder is a large native dependency
// (e.g. a VideoToolbox-backed stack or a vendored C library) that is not
// available in this package. Rather than pull in an unavailable native stack,
// this client is split into two cleanly separated concerns:
//
//   1. `AVFoundationLiveStreamClient` — owns the RTSP SESSION STATE MACHINE and
//      the protocol surface (start/stop, frames stream, audio mute). This is
//      fully implemented and compiles cross-platform (iOS 16+ / macOS 13+).
//
//   2. `RTSPTransport` — a protocol describing the lower-level RTP transport +
//      H.264 decode. The client drives it through the RTSP verbs and consumes
//      the frames it produces. A real implementation (VideoToolbox + an RTP
//      depacketizer, or a vendored native lib) can be injected later WITHOUT
//      touching the client or any application layer.
//
// `DefaultRTSPTransport` is a placeholder transport that establishes and tracks
// the session state machine and wires frame delivery through to the client's
// `AsyncStream`, with TODO markers where the native RTP receive + decode hook
// up. It lets the whole app compile and be architecturally faithful today, and
// is the single file to replace when a native decoder becomes available.
// ─────────────────────────────────────────────────────────────────────────

#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

// MARK: - Errors

/// Typed errors raised during the live-stream session lifecycle. Keeping these
/// specific lets `Live_Preview` distinguish a transport/negotiation failure
/// (surface stream-unavailable + retry, R2.7) from an invalid-state misuse.
public enum LiveStreamError: Error, Equatable {
    /// The RTSP URL did not use the expected `rtsp://` scheme.
    case invalidURL(String)
    /// Session negotiation (DESCRIBE/SETUP/PLAY) failed before any frame.
    case negotiationFailed(String)
    /// An operation was requested in a state that does not allow it (e.g.
    /// `stop` on a handle that is not the active session).
    case invalidState(String)
    /// The transport reported a fatal error while streaming.
    case transportFailed(String)
}

// MARK: - RTSP session state

/// The RTSP session state machine states, in lifecycle order.
///
/// A live session advances `idle → describing → settingUp → playing` on
/// `start`, may toggle `playing ⇄ paused`, and returns to `idle` on `stop`
/// (TEARDOWN). Modeled explicitly so the client can reject out-of-order verbs
/// and so a future native transport has a precise contract to satisfy.
public enum RTSPSessionState: Equatable, Sendable {
    /// No session; before DESCRIBE or after TEARDOWN.
    case idle
    /// DESCRIBE issued: fetching the media description (SDP).
    case describing
    /// SETUP issued: negotiating RTP transport for each media track.
    case settingUp
    /// PLAY accepted: media is flowing.
    case playing
    /// PAUSE accepted: session held open but media is not flowing.
    case paused
}

/// The negotiated media description produced by DESCRIBE/SETUP. A real
/// transport parses this from the camera's SDP; the placeholder synthesizes a
/// reasonable default. `audioAvailable` drives the Live_Preview mute control
/// (R2.6).
public struct RTSPMediaDescription: Equatable, Sendable {
    /// Opaque RTSP session identifier returned by the camera on SETUP.
    public let sessionID: String
    /// Whether the described media contains an audio track (R2.6).
    public let audioAvailable: Bool

    public init(sessionID: String, audioAvailable: Bool) {
        self.sessionID = sessionID
        self.audioAvailable = audioAvailable
    }
}

// MARK: - Transport seam

/// The lower-level RTP transport + H.264 decode behind the RTSP verbs.
///
/// This is the injectable seam that keeps `AVFoundationLiveStreamClient` free of
/// any unavailable native RTSP/H.264 stack. The client calls these in RTSP
/// order; the transport is responsible for the actual network RTP receive,
/// depacketization, and decode, pushing each `DecodedFrame` to the supplied
/// sink.
///
/// Conformers must be `Sendable`: the client may drive them from async contexts.
///
/// Implementation note for a future native transport:
///   • `describe` → RTSP DESCRIBE: fetch SDP, decide `audioAvailable`.
///   • `setup`    → RTSP SETUP: negotiate RTP channels, bind UDP/TCP transport.
///   • `play`     → RTSP PLAY: begin RTP receive loop; depacketize + decode
///                   H.264 NAL units (VideoToolbox) and emit `DecodedFrame`s.
///   • `pause`    → RTSP PAUSE: stop media without tearing down the session.
///   • `teardown` → RTSP TEARDOWN: stop receive loop, release decoder, free
///                   sockets.
///   • `setAudioMuted` → gate audio render without renegotiating.
public protocol RTSPTransport: Sendable {
    /// RTSP DESCRIBE + SETUP: negotiate the session for `url` and return the
    /// media description. Throws `LiveStreamError` on negotiation failure.
    func describeAndSetup(url: URL) async throws -> RTSPMediaDescription

    /// RTSP PLAY: begin media flow for `sessionID`, delivering each decoded
    /// frame to `sink` until `pause`/`teardown`.
    func play(sessionID: String, sink: @escaping @Sendable (DecodedFrame) -> Void) async throws

    /// RTSP PAUSE: suspend media flow without tearing down `sessionID`.
    func pause(sessionID: String) async

    /// RTSP TEARDOWN: end `sessionID` and release all resources.
    func teardown(sessionID: String) async

    /// Mute/unmute audio render for the active session.
    func setAudioMuted(_ muted: Bool)
}

// MARK: - Default (placeholder) transport

/// A dependency-free placeholder `RTSPTransport`.
///
/// It implements the RTSP session negotiation as a state machine and wires the
/// frame-delivery path end to end, but does NOT perform real RTP receive or
/// H.264 decode — that is the native hookup marked `TODO` below. This lets the
/// client and the whole app compile and be exercised structurally today.
///
/// Swap this out by injecting a native `RTSPTransport` into
/// `AVFoundationLiveStreamClient(transport:)`; no other code changes.
public final class DefaultRTSPTransport: RTSPTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var muted = false
    /// Whether the described media should report an audio track. Configurable
    /// so the mute-control path (R2.6) can be modeled without a live camera.
    private let audioAvailable: Bool

    public init(audioAvailable: Bool = true) {
        self.audioAvailable = audioAvailable
    }

    public func describeAndSetup(url: URL) async throws -> RTSPMediaDescription {
        // A real transport issues RTSP DESCRIBE here, parses the returned SDP to
        // learn the H.264 track parameters (SPS/PPS) and whether an audio track
        // is present, then issues RTSP SETUP to negotiate an RTP transport per
        // track and capture the camera's `Session:` header.
        //
        // TODO(native): replace with an actual DESCRIBE/SETUP exchange over the
        // control connection and parse the real SDP. The synthesized session id
        // below stands in for the camera-issued `Session:` value.
        let sessionID = "rtsp-\(UUID().uuidString)"
        return RTSPMediaDescription(sessionID: sessionID, audioAvailable: audioAvailable)
    }

    public func play(sessionID: String, sink: @escaping @Sendable (DecodedFrame) -> Void) async throws {
        // A real transport issues RTSP PLAY and starts the RTP receive loop:
        // read RTP packets, reassemble H.264 NAL units (handling FU-A
        // fragmentation and STAP-A aggregation), feed them to a VideoToolbox
        // decode session, and push each resulting frame to `sink` as a
        // `DecodedFrame` (opaque pixel buffer + dimensions + PTS).
        //
        // TODO(native): wire the RTP receive + H.264 depacketize + VideoToolbox
        // decode pipeline here and call `sink(frame)` for each decoded frame.
        // The placeholder emits no frames, so Live_Preview's "no first frame
        // within 5s" path (R2.7) is what exercises until the native hookup
        // lands. The `sink` closure is intentionally retained by the real loop.
        _ = sink
    }

    public func pause(sessionID: String) async {
        // TODO(native): issue RTSP PAUSE and suspend the RTP receive loop.
    }

    public func teardown(sessionID: String) async {
        // TODO(native): issue RTSP TEARDOWN, stop the receive loop, release the
        // decode session, and close transport sockets.
    }

    public func setAudioMuted(_ muted: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.muted = muted
        // TODO(native): mute/unmute the audio render node without renegotiating.
    }
}

// MARK: - Client

/// The concrete `LiveStreamClient` for Live_Preview.
///
/// Owns the RTSP session state machine and the protocol surface. Delegates the
/// actual RTP transport + H.264 decode to an injected `RTSPTransport` (default:
/// `DefaultRTSPTransport`). AVFoundation is imported for the eventual
/// audio-session/render integration but no `rtsp://`-unsupported `AVPlayer`
/// path is used, so this compiles on both iOS 16+ and macOS 13+.
///
/// Thread-safety: mutable session state is guarded by a lock and the type is
/// `Sendable`. `start`/`stop` are async; `frames`, `audioAvailable`, and
/// `setAudioMuted` are callable from any context.
public final class AVFoundationLiveStreamClient: LiveStreamClient, @unchecked Sendable {

    // MARK: Dependencies

    private let transport: RTSPTransport

    // MARK: Session state (lock-guarded)

    private let lock = NSLock()
    private var state: RTSPSessionState = .idle
    private var activeHandle: LiveStreamHandle?
    private var activeSessionID: String?
    private var _audioAvailable: Bool = false
    private var _muted: Bool = false
    /// The task running the RTSP PLAY receive loop; cancelled on TEARDOWN.
    private var playTask: Task<Void, Never>?

    // MARK: Frame stream

    // A single continuation feeds the public `frames` stream. The stream lives
    // for the client's lifetime; `start`/`stop` route a session's frames through
    // it, and `deinit` finishes it. Buffering is bounded so a slow renderer
    // drops the oldest frames rather than growing unbounded — live preview wants
    // the newest frame, not a backlog (R2.1 latency bound).
    private let _frames: AsyncStream<DecodedFrame>
    private let framesContinuation: AsyncStream<DecodedFrame>.Continuation

    // MARK: Init

    /// Creates a live-stream client.
    ///
    /// - Parameter transport: the lower-level RTP/decode seam. Defaults to
    ///   `DefaultRTSPTransport`, which runs the session state machine without a
    ///   native decoder; inject a native transport to deliver real frames.
    public init(transport: RTSPTransport = DefaultRTSPTransport()) {
        self.transport = transport
        var continuation: AsyncStream<DecodedFrame>.Continuation!
        self._frames = AsyncStream<DecodedFrame>(
            bufferingPolicy: .bufferingNewest(8)
        ) { continuation = $0 }
        self.framesContinuation = continuation
    }

    deinit {
        playTask?.cancel()
        framesContinuation.finish()
    }

    // MARK: - LiveStreamClient

    /// Opens the stream: validates the RTSP URL, runs DESCRIBE/SETUP to
    /// negotiate media, then PLAY to begin frame flow, returning a handle that
    /// identifies the session for `stop` (R2.1).
    ///
    /// Honors cooperative cancellation: a caller-imposed open timeout (R2.2/R2.7)
    /// maps to task cancellation, which propagates out of the awaited transport
    /// negotiation.
    public func start(url: URL) async throws -> LiveStreamHandle {
        // Validate the control URL scheme up front. The media channel is RTSP
        // (R2.1); a non-rtsp URL is a programming/adapter error, surfaced as a
        // typed failure rather than a late transport error.
        guard url.scheme?.lowercased() == "rtsp" else {
            throw LiveStreamError.invalidURL(url.absoluteString)
        }

        // Enforce single active session: a new start tears down any prior one so
        // the state machine never has two concurrent `playing` sessions.
        await stopActiveSessionIfNeeded()

        setState(.describing)

        // DESCRIBE + SETUP. Cancellation (open timeout) throws out here.
        let media: RTSPMediaDescription
        do {
            setState(.settingUp)
            media = try await transport.describeAndSetup(url: url)
        } catch is CancellationError {
            setState(.idle)
            throw CancellationError()
        } catch {
            setState(.idle)
            throw LiveStreamError.negotiationFailed(String(describing: error))
        }

        let handle = LiveStreamHandle(id: media.sessionID)

        withLock {
            activeHandle = handle
            activeSessionID = media.sessionID
            _audioAvailable = media.audioAvailable
            // Apply any mute preference chosen before the session existed.
            transport.setAudioMuted(_muted)
            state = .playing
        }

        // PLAY: start the receive loop on a detached task so `start` returns
        // promptly with the handle while frames arrive asynchronously (R2.1).
        // Frames are routed into the shared `frames` stream.
        let continuation = framesContinuation
        let sessionID = media.sessionID
        let task = Task { [transport] in
            do {
                try await transport.play(sessionID: sessionID) { frame in
                    continuation.yield(frame)
                }
            } catch {
                // A transport failure ends media flow; the session is left for
                // the caller to `stop`. Live_Preview observes the frame drought
                // and surfaces stream-unavailable + retry (R2.7).
            }
        }
        withLock { playTask = task }

        return handle
    }

    /// Tears down the stream (RTSP TEARDOWN) for `handle`. No-op if `handle` is
    /// not the active session, so a stale teardown is harmless (R2.5).
    public func stop(_ handle: LiveStreamHandle) async {
        let sessionID: String? = withLock {
            guard activeHandle == handle else { return nil }
            return activeSessionID
        }
        guard let sessionID else { return }
        await teardown(sessionID: sessionID)
    }

    /// The stream of decoded video frames delivered while a session is playing.
    public var frames: AsyncStream<DecodedFrame> { _frames }

    /// Whether the current session carries an audio track (R2.6). `false` until
    /// a session has been negotiated.
    public var audioAvailable: Bool { withLock { _audioAvailable } }

    /// Mutes or unmutes live audio playback. Remembered across sessions so a
    /// preference set before `start` applies once media begins (R2.6).
    public func setAudioMuted(_ muted: Bool) {
        withLock {
            _muted = muted
            transport.setAudioMuted(muted)
        }
    }

    // MARK: - Session teardown helpers

    /// Tears down whatever session is currently active, if any.
    private func stopActiveSessionIfNeeded() async {
        let sessionID: String? = withLock { activeSessionID }
        guard let sessionID else { return }
        await teardown(sessionID: sessionID)
    }

    /// Cancels the PLAY loop, issues TEARDOWN, and resets to `idle`.
    private func teardown(sessionID: String) async {
        let task: Task<Void, Never>? = withLock {
            let t = playTask
            playTask = nil
            return t
        }
        task?.cancel()
        await transport.teardown(sessionID: sessionID)
        withLock {
            if activeSessionID == sessionID {
                activeHandle = nil
                activeSessionID = nil
                _audioAvailable = false
                state = .idle
            }
        }
    }

    // MARK: - State helpers

    private func setState(_ newState: RTSPSessionState) {
        withLock { state = newState }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
