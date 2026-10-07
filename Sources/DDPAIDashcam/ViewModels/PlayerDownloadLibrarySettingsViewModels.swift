// Media_Player / Download_Manager / Local_Library / Settings_Controller view models
//
// Task 15.2: `MediaPlayerViewModel`, `DownloadViewModel`,
// `LocalLibraryViewModel`, and `SettingsViewModel`.
//
// Design reference: design.md → Architecture (MVVM + unidirectional state).
// Each view model is a thin `@MainActor ObservableObject` presentation layer
// that exposes `@Published` view state derived from its subsystem and forwards
// user intents. No business logic lives here — source selection, seek clamping,
// queue ordering, resume gating, storage checks, delete semantics, and the
// optimistic-with-revert write pattern all live in the subsystem services.
// Display strings use the pure ClipLogic helpers (duration H:M:S, size MB).

import Combine
import Foundation

// MARK: - MediaPlayerViewModel (R4.2, R4.3)

/// Presentation state for the playback screen. Mirrors `MediaPlaying`'s
/// position, duration, and playback state, exposes H:M:S-formatted position /
/// duration strings (R4.3), and forwards play / pause / seek / retry intents.
/// Seek clamping to `0...duration` is performed by the subsystem (R4.2); this
/// view model forwards the requested position unchanged.
@MainActor
public final class MediaPlayerViewModel: ObservableObject {

    // MARK: Observable view state

    /// Current playback position (R4.3).
    @Published public private(set) var position: Duration

    /// Total duration of the selected clip (R4.3).
    @Published public private(set) var duration: Duration

    /// Current playback state (R4.1, R4.4, R4.7).
    @Published public private(set) var playbackState: PlaybackState

    // MARK: Dependencies

    private let player: MediaPlaying
    private var cancellables: Set<AnyCancellable> = []

    public init(player: MediaPlaying) {
        self.player = player
        self.position = player.position
        self.duration = player.duration
        self.playbackState = player.playbackState
        bind()
    }

    private func bind() {
        guard let concrete = player as? MediaPlayer else { return }
        concrete.$position
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.position = $0 }
            .store(in: &cancellables)
        concrete.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &cancellables)
        concrete.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.playbackState = $0 }
            .store(in: &cancellables)
    }

    // MARK: Derived display (R4.3)

    /// Current position formatted as hours:minutes:seconds via ClipLogic (R4.3).
    public var positionText: String { formatDuration(position) }

    /// Total duration formatted as hours:minutes:seconds via ClipLogic (R4.3).
    public var durationText: String { formatDuration(duration) }

    /// Playback progress in `0...1` for a scrubber; 0 when duration is zero.
    public var progressFraction: Double {
        let total = duration.components.seconds
        guard total > 0 else { return 0 }
        let current = position.components.seconds
        return min(1, max(0, Double(current) / Double(total)))
    }

    /// Whether playback is active (R4.1).
    public var isPlaying: Bool {
        if case .playing = playbackState { return true }
        return false
    }

    /// A failure message with a retry affordance, else nil (R4.4).
    public var failureMessage: String? {
        if case .failed(let message) = playbackState { return message }
        return nil
    }

    /// An unavailable message (not local, not connected), else nil (R4.7).
    public var unavailableMessage: String? {
        if case .unavailable(let message) = playbackState { return message }
        return nil
    }

    /// Whether a retry control should be offered (R4.5).
    public var canRetry: Bool { failureMessage != nil }

    // MARK: Intents

    /// Begins playback of a clip (R4.1).
    public func play(_ clip: ClipID) async { await player.play(clip) }

    /// Pauses playback (R4.2).
    public func pause() { player.pause() }

    /// Seeks to a position; the subsystem clamps it to `0...duration` (R4.2).
    public func seek(to position: Duration) { player.seek(to: position) }

    /// Re-attempts playback of the most recently selected clip (R4.5).
    public func retry() async { await player.retry() }
}

// MARK: - DownloadViewModel (R5.2, R5.4)

/// A single download row prepared for display: the subsystem's per-task snapshot
/// augmented with a formatted size string (MB) via ClipLogic and a bounded
/// percent for the progress bar (R5.2).
public struct DownloadRowViewData: Identifiable, Equatable {
    /// Underlying per-task snapshot from the Download_Manager.
    public let task: DownloadTaskState

    public init(task: DownloadTaskState) {
        self.task = task
    }

    /// Stable identity for SwiftUI lists.
    public var id: ClipID { task.clipID }

    /// Clip identifier.
    public var clipID: ClipID { task.clipID }

    /// Selection order position (R5.4).
    public var selectionIndex: Int { task.selectionIndex }

    /// Lifecycle status.
    public var status: DownloadStatus { task.status }

    /// Integer transfer percent in `0...100` for the progress bar (R5.2).
    public var percent: Int {
        switch task.status {
        case .inProgress(let percent): return percent
        case .completed: return 100
        case .interrupted, .queued, .canceled, .failedInsufficientStorage:
            return progressPercent(completed: task.completedBytes, total: task.totalBytes)
        }
    }

    /// Total clip size formatted in megabytes via ClipLogic.
    public var sizeText: String {
        String(format: "%.2f MB", megabytes(fromBytes: task.totalBytes))
    }

    /// Whether the task is interrupted and offers a resume affordance (R5.5–R5.7).
    public var isInterrupted: Bool {
        if case .interrupted = task.status { return true }
        return false
    }

    /// An insufficient-storage message with required/available amounts, else nil
    /// (R5.8).
    public var insufficientStorageMessage: String? {
        if case .failedInsufficientStorage(let required, let available) = task.status {
            return "Not enough storage. Needs \(megabytes(fromBytes: required)) MB, "
                + "\(megabytes(fromBytes: available)) MB free."
        }
        return nil
    }
}

/// Presentation state for the download queue screen. Consumes the
/// Download_Manager actor's `progress` `AsyncStream` and republishes the queue
/// snapshot as `@Published` state on the main actor (R5.2), and forwards the
/// enqueue / cancel / resume intents. Queue ordering, the 100-clip cap, resume
/// gating, and storage checks all live in the actor (R5.4, R5.6–R5.8).
@MainActor
public final class DownloadViewModel: ObservableObject {

    // MARK: Observable view state

    /// Display rows for the queue, in selection order (R5.4), each carrying the
    /// bounded integer percent for its progress bar (R5.2).
    @Published public private(set) var rows: [DownloadRowViewData] = []

    /// The clip currently transferring, if any.
    @Published public private(set) var activeClipID: ClipID?

    /// Latest user-facing message (e.g. queue-cap-exceeded), or nil.
    @Published public private(set) var message: String?

    // MARK: Dependencies

    private let manager: DownloadManager

    /// Task consuming the actor's progress stream and republishing snapshots on
    /// the main actor. Cancelled on `stopObserving` / deinit.
    private var observationTask: Task<Void, Never>?

    public init(manager: DownloadManager) {
        self.manager = manager
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: Progress stream consumption (R5.2)

    /// Begins consuming the Download_Manager's progress `AsyncStream` and
    /// republishing each queue snapshot to the `@Published` view state on the
    /// main actor (R5.2). Also seeds the current snapshot so the view has state
    /// before the next emission.
    public func startObserving() {
        guard observationTask == nil else { return }
        let manager = self.manager
        observationTask = Task { [weak self] in
            // Seed with the current snapshot.
            let initial = await manager.queueState()
            await self?.apply(initial)
            // Republish every subsequent snapshot on the main actor.
            for await snapshot in manager.progress {
                if Task.isCancelled { return }
                await self?.apply(snapshot)
            }
        }
    }

    /// Stops consuming the progress stream (e.g. when the screen disappears).
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Applies a queue snapshot to the observable view state, ordering rows by
    /// selection index (R5.4).
    private func apply(_ snapshot: DownloadQueueState) {
        rows = snapshot.tasks
            .sorted { $0.selectionIndex < $1.selectionIndex }
            .map(DownloadRowViewData.init)
        activeClipID = snapshot.active
    }

    // MARK: Intents (R5.4, R5.6, R5.7, R5.9)

    /// Enqueues clips for download, preserving selection order and honoring the
    /// 100-clip cap in the actor (R5.4). A cap-exceeded error is surfaced as a
    /// user-facing message; the first 100 clips are still enqueued.
    public func enqueue(_ clips: [ClipMetadata]) async {
        do {
            try await manager.enqueue(clips)
            message = nil
        } catch let DownloadManagerError.queueCapExceeded(cap, submitted) {
            message = "Only the first \(cap) of \(submitted) clips were queued."
        } catch {
            message = "Could not queue the selected clips."
        }
    }

    /// Cancels a clip's download; the actor stops within 2s and removes the
    /// partial file (R5.9).
    public func cancel(_ clip: ClipID) async { await manager.cancel(clip) }

    /// Resumes an interrupted download; the actor gates resume on connection
    /// (R5.6, R5.7).
    public func resume(_ clip: ClipID) async { await manager.resume(clip) }
}

// MARK: - LocalLibraryViewModel (R7.2)

/// A stored clip prepared for display: the subsystem's `StoredClip` augmented
/// with ClipLogic-formatted duration (H:M:S) and size (MB) strings and its
/// protection indicator.
public struct StoredClipViewData: Identifiable, Equatable {
    /// Underlying stored clip.
    public let clip: StoredClip

    public init(clip: StoredClip) {
        self.clip = clip
    }

    /// Stable identity for SwiftUI lists.
    public var id: ClipID { clip.metadata.id }

    /// Clip identifier.
    public var clipID: ClipID { clip.metadata.id }

    /// On-device media file URL for sharing / playback.
    public var fileURL: URL { clip.fileURL }

    /// Recording start timestamp (R7.2 ordering source).
    public var startTimestamp: Date { clip.metadata.startTimestamp }

    /// Duration formatted as hours:minutes:seconds via ClipLogic.
    public var durationText: String { formatDuration(clip.metadata.duration) }

    /// Size in megabytes via ClipLogic, formatted with two decimals.
    public var sizeText: String {
        String(format: "%.2f MB", megabytes(fromBytes: clip.metadata.sizeBytes))
    }

    /// Protection indicator — protected marker iff Emergency_Footage (R6.1).
    public var protectionMarker: ClipProtectionIndicator {
        clip.isProtected ? .protected : .unprotected
    }
}

/// Presentation state for the local library screen. Loads the Local_Library's
/// stored clips (already ordered descending by start timestamp — R7.2), exposes
/// `isEmpty` for the empty-state (R7.3), and deletes clips surfacing any failure
/// message (R7.4, R7.5). Works regardless of Connection_State (R7.1).
@MainActor
public final class LocalLibraryViewModel: ObservableObject {

    // MARK: Observable view state

    /// Display rows for the stored clips, ordered descending by start timestamp
    /// (R7.2).
    @Published public private(set) var clips: [StoredClipViewData] = []

    /// Whether the Local_Library is empty, for the empty-state message (R7.3).
    @Published public private(set) var isEmpty: Bool = true

    /// Latest user-facing message (e.g. delete failure), or nil (R7.5).
    @Published public private(set) var message: String?

    // MARK: Dependencies

    private let library: LocalLibrary

    public init(library: LocalLibrary) {
        self.library = library
    }

    // MARK: Intents / loading

    /// Loads all stored clips (R7.1, R7.2) and recomputes the empty-state flag
    /// (R7.3). Available offline since the Local_Library is on-device.
    public func load() async {
        let stored = await library.allClips()
        clips = stored.map(StoredClipViewData.init)
        isEmpty = clips.isEmpty
        message = nil
    }

    /// Deletes a clip. On success it is removed from the displayed list and the
    /// empty-state flag is recomputed (R7.4); on failure the clip is retained
    /// and a failure message is surfaced (R7.5).
    public func delete(_ clip: ClipID) async {
        do {
            try await library.delete(clip)
            await load()
        } catch let LocalLibraryError.deletionFailed(_, failureMessage) {
            // R7.5: the subsystem retained the clip; surface its message and
            // keep the current list intact.
            message = failureMessage
        } catch {
            message = "Could not delete the clip."
        }
    }

    /// The on-device media file URL for a stored clip, for share / export, or
    /// nil if the clip is not present.
    public func fileURL(for clip: ClipID) async -> URL? {
        await library.fileURL(for: clip)
    }
}

// MARK: - SettingsViewModel (R8.1, R9.1, R10.1, R11.1, R12.1)

/// Presentation state for the settings screens. Mirrors `SettingsControlling`'s
/// per-setting states and overall sync status, and forwards the sync / read /
/// write / lock intents. The optimistic-with-revert write pattern, availability
/// gating, and convergence to the camera-reported value all live in the
/// subsystem; this view model only reflects the resulting state (R8–R12).
@MainActor
public final class SettingsViewModel: ObservableObject {

    // MARK: Observable view state

    /// Overall synchronization status (R12.1, R12.2).
    @Published public private(set) var syncStatus: SettingsSyncStatus

    /// Latest user-facing message, or nil.
    @Published public private(set) var message: String?

    /// Displayed state for each tracked setting, keyed by `SettingKey`
    /// (R8.1, R9.1, R10.1, R11.1).
    @Published public private(set) var states: [SettingKey: SettingState]

    // MARK: Dependencies

    private let controller: SettingsControlling
    private var cancellables: Set<AnyCancellable> = []

    public init(controller: SettingsControlling) {
        self.controller = controller
        self.syncStatus = controller.syncStatus
        self.message = controller.message
        self.states = [:]
        seedStates()
        bind()
    }

    private func seedStates() {
        let keys: [SettingKey] = [
            .resolution, .collisionSensitivity, .audioRecording,
            .parkingMode, .parkingSensitivity
        ]
        for key in keys {
            if let state = controller.state(for: key) {
                states[key] = state
            }
        }
    }

    private func bind() {
        guard let concrete = controller as? SettingsController else { return }
        concrete.$syncStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncStatus = $0 }
            .store(in: &cancellables)
        concrete.$message
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.message = $0 }
            .store(in: &cancellables)
        concrete.$states
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.states = $0 }
            .store(in: &cancellables)
    }

    // MARK: Derived display

    /// The displayed state for a setting the controller is tracking (R8.1,
    /// R9.1, R10.1, R11.1).
    public func state(for key: SettingKey) -> SettingState? { states[key] }

    /// Whether a control is enabled for interaction (connected and not pending)
    /// (R8.5, R8.6, R10.6, R11.7).
    public func isEnabled(_ key: SettingKey) -> Bool {
        states[key]?.availability == .enabled
    }

    /// Whether a write is in flight for a control (shows an in-progress
    /// indicator and disables the control) (R8.6, R9.2).
    public func isPending(_ key: SettingKey) -> Bool {
        states[key]?.availability == .pending
    }

    /// Whether the settings sync is in progress (R12.1).
    public var isSyncing: Bool { syncStatus == .loading }

    /// Whether settings are unavailable after exhausting sync retries, offering
    /// a retry control (R12.2).
    public var isUnavailable: Bool { syncStatus == .unavailable }

    // MARK: Intents

    /// Synchronizes all settings from the camera on connect (R12.1, R12.2).
    public func syncAll() async { await controller.syncAll() }

    /// Reads a single setting's current value, options, and availability
    /// (R8.1, R9.1, R10.1, R11.1).
    @discardableResult
    public func readSetting(_ key: SettingKey) async -> SettingState {
        await controller.readSetting(key)
    }

    /// Writes a new value using the optimistic-with-revert pattern in the
    /// subsystem (R8.3–R8.6, R9.2–R9.5, R10.2–R10.5, R11.2–R11.6, R12.4).
    @discardableResult
    public func writeSetting(_ key: SettingKey, _ value: SettingValue) async -> WriteOutcome {
        await controller.writeSetting(key, value)
    }

    /// Toggles the audio-recording setting (R10.2, R10.3). Reads the current
    /// displayed value and writes its inverse.
    @discardableResult
    public func toggleAudioRecording() async -> WriteOutcome {
        let current: Bool
        if case .bool(let value)? = states[.audioRecording]?.currentValue {
            current = value
        } else {
            current = false
        }
        return await controller.writeSetting(.audioRecording, .bool(!current))
    }

    /// Locks or unlocks a clip for overwrite protection (R6.4–R6.7).
    @discardableResult
    public func lock(_ clip: ClipID, locked: Bool) async -> WriteOutcome {
        await controller.lock(clip, locked: locked)
    }
}
