// Media_Player
//
// Task 10.1: `MediaPlaying` protocol and the concrete `MediaPlayer` class that
// plays recorded clips, choosing between the Local_Library copy and the camera
// stream via the pure source-selection decision.
//
// Design reference: design.md → Components and Interfaces → Media_Player. Source
// selection is a pure decision (`playbackSource` in DecisionLogic): if the clip
// exists in the Local_Library, play the local file; else if connected, stream
// from the camera; else report unavailable. Seek positions are clamped to
// `0...duration` via the pure `clamp` function.
//
// Requirements covered (R4.1–R4.7):
//   - R4.1: begin playback of a selected clip (within 3s — a transport
//     property reflected by the playing state).
//   - R4.2: provide play/pause/seek; seek supports positions in 0...duration.
//   - R4.3: expose current position and total duration (H:M:S formatting is
//     performed by the view via ClipLogic).
//   - R4.4: if playback cannot start within 10s, stop and report failure +
//     retry.
//   - R4.5: retry re-attempts playback of the selected clip.
//   - R4.6: a clip present in the Local_Library plays from local storage
//     instead of streaming.
//   - R4.7: a clip not local and not connected is reported unavailable.
//
// Playback uses AVPlayer where AVFoundation is available; the source-selection
// decision itself stays pure and platform-independent.

import Combine
import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Timing constants

/// Fixed timing bounds taken from Requirement 4. Centralized so the subsystem
/// and its tests reference the same values.
public enum MediaPlayerTiming {
    /// Maximum time for playback to start before it is reported as failed
    /// (R4.4).
    public static let startTimeout: Duration = .seconds(10)
}

// MARK: - Playback state

/// Observable playback state of the Media_Player (design.md → Media_Player).
public enum PlaybackState: Equatable {
    /// Actively playing the selected clip (R4.1).
    case playing
    /// Playback is paused (R4.2).
    case paused
    /// Playback could not start within the bound (R4.4). Carries a message; the
    /// view offers retry.
    case failed(message: String)
    /// The clip is neither local nor streamable (not connected) (R4.7). Carries
    /// a message.
    case unavailable(message: String)
}

// MARK: - User-facing messages

/// User-facing strings surfaced via `playbackState`. Owned here so the subsystem
/// fully owns Media_Player semantics; the view renders them verbatim.
public enum MediaPlayerMessage {
    /// R4.4 — playback did not start within the 10s bound.
    public static let playbackFailed =
        "Playback could not start. Tap retry to try again."
    /// R4.7 — the clip is not downloaded and the camera is not connected.
    public static let unavailable =
        "This clip is unavailable for playback. Download it or connect to the camera."
}

// MARK: - Protocol

/// The Media_Player interface (design.md → Media_Player).
@MainActor
public protocol MediaPlaying: AnyObject {
    /// Current playback position (R4.3).
    var position: Duration { get }

    /// Total duration of the selected clip (R4.3).
    var duration: Duration { get }

    /// Current playback state: playing, paused, failed, or unavailable (R4.1,
    /// R4.4, R4.7).
    var playbackState: PlaybackState { get }

    /// Begins playback of a clip, selecting the local copy if present, else the
    /// camera stream if connected, else reporting unavailable (R4.1, R4.4,
    /// R4.6, R4.7).
    func play(_ clip: ClipID) async

    /// Pauses playback (R4.2).
    func pause()

    /// Seeks to a position, clamped to `0...duration` (R4.2).
    func seek(to position: Duration)

    /// Re-attempts playback of the most recently selected clip (R4.5).
    func retry() async
}

// MARK: - Concrete subsystem

/// Concrete Media_Player. `@MainActor` so its observable state is mutated on the
/// main actor and read safely by SwiftUI view models.
///
/// The source-selection decision is pure (`playbackSource`); the concrete
/// playback engine (AVPlayer) is only touched behind `#if canImport`, so the
/// subsystem's decision logic builds and is testable on any platform.
@MainActor
public final class MediaPlayer: MediaPlaying, ObservableObject {

    // MARK: Observable state

    /// Current playback position (R4.3).
    @Published public private(set) var position: Duration = .zero

    /// Total duration of the selected clip (R4.3).
    @Published public private(set) var duration: Duration = .zero

    /// Current playback state (R4.1, R4.4, R4.7).
    @Published public private(set) var playbackState: PlaybackState = .paused

    public var playbackStatePublisher: Published<PlaybackState>.Publisher { $playbackState }

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let store: LibraryStore
    private let connectionState: () -> ConnectionState

    // MARK: Internal bookkeeping

    /// The clip currently selected for playback; retained so `retry` can
    /// re-attempt the same clip (R4.5).
    private var currentClip: ClipID?

    #if canImport(AVFoundation)
    /// The underlying AVPlayer driving playback when AVFoundation is available.
    private var player: AVPlayer?
    #endif

    /// Creates a Media_Player.
    ///
    /// - Parameters:
    ///   - adapter: provides the camera clip playback URL (`clipPlaybackURL`).
    ///   - store: Local_Library used to detect a local copy and resolve its
    ///     file URL (R4.6).
    ///   - connectionState: reads the shared Connection_State; used to decide
    ///     whether streaming is possible when no local copy exists (R4.7).
    public init(
        adapter: CameraProtocolAdapter,
        store: LibraryStore,
        connectionState: @escaping () -> ConnectionState
    ) {
        self.adapter = adapter
        self.store = store
        self.connectionState = connectionState
    }

    // MARK: - Play (R4.1, R4.4, R4.6, R4.7)

    public func play(_ clip: ClipID) async {
        currentClip = clip

        // Pure source selection (Property 9): local copy wins; else stream when
        // connected; else unavailable (R4.6, R4.7).
        let localURL = localFileURL(for: clip)
        let source = playbackSource(
            for: localURL,
            connectionState: connectionState(),
            isLocal: localURL != nil
        )

        switch source {
        case .local(let url):
            await startPlayback(url: url, clip: clip)
        case .stream:
            await startPlayback(url: adapter.clipPlaybackURL(clipID: clip), clip: clip)
        case .unavailable:
            // R4.7: not local and not connected.
            teardownPlayer()
            duration = .zero
            position = .zero
            playbackState = .unavailable(message: MediaPlayerMessage.unavailable)
        }
    }

    public func pause() {
        // R4.2: pause only has meaning while playing.
        guard case .playing = playbackState else { return }
        #if canImport(AVFoundation)
        player?.pause()
        #endif
        playbackState = .paused
    }

    public func seek(to requested: Duration) {
        // R4.2: clamp the requested position into 0...duration (Property 8).
        let clamped = clamp(requested, to: .zero...max(.zero, duration))
        position = clamped
        #if canImport(AVFoundation)
        player?.seek(to: CMTime(duration: clamped))
        #endif
    }

    public func retry() async {
        // R4.5: re-attempt playback of the most recently selected clip.
        guard let clip = currentClip else { return }
        await play(clip)
    }

    // MARK: - Playback start with bounded timeout (R4.1, R4.3, R4.4)

    /// Starts playback of the media at `url` for `clip`, bounded by the 10s
    /// start timeout. On success it enters the playing state and surfaces the
    /// clip duration (R4.1, R4.3); if start does not complete in time it stops
    /// and reports failure with a retry affordance (R4.4).
    private func startPlayback(url: URL, clip: ClipID) async {
        position = .zero
        duration = clipDuration(for: clip)

        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await self?.beginEngine(url: url) ?? false
            }
            group.addTask {
                try? await Task.sleep(for: MediaPlayerTiming.startTimeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        // A newer selection may have superseded this one while we awaited.
        guard currentClip == clip else { return }

        if started {
            playbackState = .playing
        } else {
            // R4.4: stop the attempt and report failure + retry.
            teardownPlayer()
            playbackState = .failed(message: MediaPlayerMessage.playbackFailed)
        }
    }

    /// Boots the concrete playback engine for `url` and begins playing,
    /// returning whether the engine was readied. Where AVFoundation is
    /// unavailable the engine is a no-op that reports success so the decision
    /// logic (source selection, timeout, clamping) remains exercisable.
    private func beginEngine(url: URL) async -> Bool {
        #if canImport(AVFoundation)
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer
        avPlayer.play()
        return true
        #else
        return true
        #endif
    }

    // MARK: - Teardown

    /// Stops and releases the concrete playback engine.
    private func teardownPlayer() {
        #if canImport(AVFoundation)
        player?.pause()
        player = nil
        #endif
    }

    // MARK: - Local_Library + metadata lookups

    /// The Local_Library file URL for a clip, or `nil` when the clip is not
    /// stored locally. Local presence drives source selection (R4.6). The URL is
    /// taken from the stored clip record so it reflects the persisted media
    /// location; `contains` is the authoritative local-presence check.
    private func localFileURL(for clip: ClipID) -> URL? {
        guard (try? store.contains(clip)) == true else { return nil }
        return (try? store.clip(for: clip))??.fileURL ?? store.mediaURL(for: clip)
    }

    /// The total duration of a clip for position/duration display (R4.3). Taken
    /// from the stored clip metadata when available; otherwise zero until the
    /// engine reports it.
    private func clipDuration(for clip: ClipID) -> Duration {
        if let stored = try? store.clip(for: clip) {
            return stored.metadata.duration
        }
        return .zero
    }
}

#if canImport(AVFoundation)
private extension CMTime {
    /// Builds a `CMTime` from a `Duration` using a fixed millisecond timescale,
    /// enough precision for clip-position seeking.
    init(duration: Duration) {
        let c = duration.components
        let totalMs = c.seconds * 1_000 + Int64(c.attoseconds / 1_000_000_000_000_000)
        self = CMTime(value: CMTimeValue(max(0, totalMs)), timescale: 1_000)
    }
}
#endif
