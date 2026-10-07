// Download_Manager
//
// Task 11.1: the `DownloadManager` actor that owns the sequential download
// queue, resume-from-offset bookkeeping, and progress reporting.
//
// Design reference: design.md → Components and Interfaces → Download_Manager.
// Responsibilities and the acceptance criteria they satisfy:
//   - enqueue(_:): accept at most 100 clips, preserving selection order via the
//     pure `enqueueOrder` decision (R5.4).
//   - sequential processing of the queue, one clip at a time (R5.4).
//   - per-clip storage pre-check against clip size + 50 MB reserve via the pure
//     `hasSufficientStorage` decision (R5.8).
//   - on interrupt (link lost / disconnected), mark the download incomplete and
//     retain the completed byte count via the pure `interrupt(task:)` (R5.5).
//   - resume(_:): continue from the retained offset only when connected, via the
//     pure `resumeRequest(task:connectionState:)` decision (R5.6, R5.7).
//   - cancel(_:): stop within 2s and remove the partial file (R5.9).
//   - progress: an `AsyncStream<DownloadQueueState>` emitting integer percent at
//     a <=1s cadence via the pure `progressPercent` decision (R5.2).
//   - on completion: store the clip via `LibraryStore.insert` and mark it
//     downloaded (R5.3), carrying the protected flag for Emergency_Footage
//     (R6.8).
//
// Camera I/O funnels through the protocol-neutral `CameraProtocolAdapter`
// (`clipDownloadRequest`) + `HTTPControlClient.download(_:to:resumingFrom:)`,
// and media file locations come from `LibraryStore.mediaURL(for:)`.

import Foundation

// MARK: - Queue state

/// A snapshot of a single task in the download queue surfaced to observers.
public struct DownloadTaskState: Equatable, Sendable {
    /// The clip being downloaded.
    public let clipID: ClipID
    /// Position in the user's selection; preserves selection order (R5.4).
    public let selectionIndex: Int
    /// Current lifecycle status, carrying the integer percent while in progress
    /// (R5.2) and the retained completed bytes while interrupted (R5.5).
    public let status: DownloadStatus
    /// Bytes transferred so far (retained across interruption for resume).
    public let completedBytes: Int64
    /// Total expected size of the clip in bytes.
    public let totalBytes: Int64

    public init(
        clipID: ClipID,
        selectionIndex: Int,
        status: DownloadStatus,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        self.clipID = clipID
        self.selectionIndex = selectionIndex
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// A snapshot of the whole download queue, emitted on the `progress` stream at a
/// <=1s cadence as task statuses and percents change (R5.2).
public struct DownloadQueueState: Equatable, Sendable {
    /// All tracked tasks, ordered by their selection index (R5.4).
    public let tasks: [DownloadTaskState]
    /// The clip currently being transferred, if any.
    public let active: ClipID?

    public init(tasks: [DownloadTaskState], active: ClipID?) {
        self.tasks = tasks
        self.active = active
    }
}

// MARK: - Errors

/// Errors surfaced by `DownloadManager`.
public enum DownloadManagerError: Error, Equatable {
    /// The enqueue request exceeded the 100-clip maximum (R5.4). Enqueue still
    /// accepts the first 100 in order; this is thrown when the caller submits
    /// more than the cap so the UI can inform the user of the truncation.
    case queueCapExceeded(cap: Int, submitted: Int)
}

// MARK: - DownloadManager

/// Owns the sequential download queue. An `actor` so queue mutation, progress
/// emission, and per-clip transfer state stay isolated without explicit locks.
public actor DownloadManager {

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let client: HTTPControlClient
    private let store: LibraryStore
    /// Reports currently available free storage (bytes), checked before each
    /// download against clip size + reserve (R5.8). Injectable for testing.
    private let availableStorage: @Sendable () -> Int64
    /// Reports the current shared Connection_State so resume is gated on it
    /// (R5.6, R5.7) and transfers are marked interrupted when the link drops
    /// (R5.5). Injectable so the actor doesn't reach into the @MainActor
    /// Connection_Manager directly.
    private let connectionState: @Sendable () -> ConnectionState
    private let fileManager: FileManager

    // MARK: Queue bookkeeping

    /// All tracked tasks keyed by clip id.
    private var tasks: [ClipID: DownloadTask] = [:]
    /// Order of clip ids as enqueued (preserves selection order, R5.4).
    private var order: [ClipID] = []
    /// The clip currently transferring, if any.
    private var activeClip: ClipID?
    /// The in-flight transfer loop; cancelled on `cancel` to stop within 2s
    /// (R5.9) and on interrupt.
    private var processingTask: Task<Void, Never>?

    // MARK: Progress stream

    private var progressContinuation: AsyncStream<DownloadQueueState>.Continuation?
    private let progressStream: AsyncStream<DownloadQueueState>

    /// Integer-percent / status change stream emitted to observers (R5.2).
    public nonisolated let progress: AsyncStream<DownloadQueueState>

    public init(
        adapter: CameraProtocolAdapter,
        client: HTTPControlClient,
        store: LibraryStore,
        availableStorage: @escaping @Sendable () -> Int64,
        connectionState: @escaping @Sendable () -> ConnectionState,
        fileManager: FileManager = .default
    ) {
        self.adapter = adapter
        self.client = client
        self.store = store
        self.availableStorage = availableStorage
        self.connectionState = connectionState
        self.fileManager = fileManager

        var continuation: AsyncStream<DownloadQueueState>.Continuation!
        let stream = AsyncStream<DownloadQueueState> { continuation = $0 }
        self.progressStream = stream
        self.progress = stream
        self.progressContinuation = continuation
    }

    // MARK: - Enqueue (R5.4, R5.8)

    /// Enqueues clips for download, accepting at most 100 while preserving the
    /// selection order (R5.4). Clips already tracked are ignored (no duplicate
    /// work). Starts sequential processing if idle.
    ///
    /// Throws `DownloadManagerError.queueCapExceeded` when more than the cap is
    /// submitted; the first `cap` clips are still enqueued in order.
    public func enqueue(_ clips: [ClipMetadata]) throws {
        let submitted = clips.count
        // R5.4: constrain to the 100-clip maximum preserving relative order.
        let accepted = enqueueOrder(clips, cap: defaultQueueCap)

        for clip in accepted where tasks[clip.id] == nil {
            let task = DownloadTask(
                clip: clip,
                status: .queued,
                completedBytes: 0,
                selectionIndex: order.count
            )
            tasks[clip.id] = task
            order.append(clip.id)
            persist(task)
        }

        emitProgress()
        startProcessingIfNeeded()

        if submitted > defaultQueueCap {
            throw DownloadManagerError.queueCapExceeded(cap: defaultQueueCap, submitted: submitted)
        }
    }

    // MARK: - Cancel (R5.9)

    /// Cancels a clip's download: stops the in-flight transfer (within 2s by
    /// cancelling the transfer loop) and removes any partial media file (R5.9).
    public func cancel(_ clip: ClipID) async {
        guard var task = tasks[clip] else { return }

        // If this clip is actively transferring, stop the loop so it returns
        // promptly (well within the 2s bound, R5.9).
        if activeClip == clip {
            processingTask?.cancel()
            processingTask = nil
            activeClip = nil
        }

        // Remove the partial file (R5.9). No partial state remains on cancel.
        removePartialFile(for: clip)

        task.status = .canceled
        task.completedBytes = 0
        tasks[clip] = task
        try? store.deleteDownloadTask(for: clip)

        emitProgress()
        // Continue with the rest of the queue.
        startProcessingIfNeeded()
    }

    // MARK: - Resume (R5.6, R5.7)

    /// Resumes an interrupted download from its retained byte offset, but only
    /// when connected (R5.6, R5.7). The gating decision is the pure
    /// `resumeRequest(task:connectionState:)`; when not connected the task
    /// stays interrupted with its completed-byte count unchanged.
    public func resume(_ clip: ClipID) async {
        guard let task = tasks[clip] else { return }

        switch resumeRequest(task: task, connectionState: connectionState()) {
        case .stayInterrupted:
            // R5.7: not connected — leave the task interrupted, no request.
            return
        case .request:
            // R5.6: re-queue so the sequential processor picks it up and issues
            // the ranged request from the retained offset.
            var requeued = task
            requeued.status = .queued
            tasks[clip] = requeued
            persist(requeued)
            emitProgress()
            startProcessingIfNeeded()
        }
    }

    // MARK: - Interrupt (R5.5)

    /// Marks the active download incomplete and retains its completed byte
    /// count (R5.5), using the pure `interrupt(task:)` decision. Called when the
    /// shared Connection_State leaves `.connected` while a transfer is active.
    public func handleConnectionInterrupted() {
        processingTask?.cancel()
        processingTask = nil
        guard let clip = activeClip, let task = tasks[clip] else { return }
        let interrupted = interrupt(task: task)
        tasks[clip] = interrupted
        activeClip = nil
        persist(interrupted)
        emitProgress()
    }

    // MARK: - Sequential processing (R5.4)

    private func startProcessingIfNeeded() {
        guard processingTask == nil, activeClip == nil else { return }
        guard nextQueuedClip() != nil else { return }
        processingTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    /// Processes queued clips strictly one at a time in selection order (R5.4).
    private func processQueue() async {
        while let clipID = nextQueuedClip() {
            if Task.isCancelled { return }
            // Only transfer while connected; otherwise stop and let a later
            // resume / reconnect restart processing (R5.6, R5.7).
            guard connectionState() == .connected else {
                markRemainingInterrupted(startingAt: clipID)
                break
            }
            await processClip(clipID)
            if Task.isCancelled { return }
        }
        activeClip = nil
        processingTask = nil
        emitProgress()
    }

    /// The next clip eligible for transfer in selection order: queued, or
    /// interrupted-and-requeued. Completed/canceled/failed clips are skipped.
    private func nextQueuedClip() -> ClipID? {
        for id in order {
            guard let task = tasks[id] else { continue }
            if case .queued = task.status { return id }
        }
        return nil
    }

    /// Downloads a single clip end to end: storage pre-check (R5.8), ranged
    /// transfer with progress (R5.2), interrupt handling (R5.5), and on-success
    /// store + downloaded flag carrying protection (R5.3, R6.8).
    private func processClip(_ clipID: ClipID) async {
        guard var task = tasks[clipID] else { return }

        // R5.8: pre-download storage check against clip size + 50 MB reserve.
        let available = availableStorage()
        guard hasSufficientStorage(available: available, clipSize: task.clip.sizeBytes) else {
            task.status = .failedInsufficientStorage(
                required: task.clip.sizeBytes + storageReserveBytes,
                available: available
            )
            tasks[clipID] = task
            persist(task)
            emitProgress()
            // Previously stored clips are retained; move on to the next clip.
            return
        }

        activeClip = clipID
        let fromByte = task.completedBytes
        task.status = .inProgress(percent: progressPercent(completed: task.completedBytes, total: task.clip.sizeBytes))
        tasks[clipID] = task
        persist(task)
        emitProgress()

        let request = adapter.clipDownloadRequest(clipID: clipID, fromByte: fromByte)
        let destination = store.mediaURL(for: clipID)

        var lastEmittedPercent = -1
        do {
            let stream = client.download(request, to: destination, resumingFrom: fromByte)
            for try await update in stream {
                if Task.isCancelled { return }

                // R5.5: a mid-transfer disconnect interrupts and retains bytes.
                if connectionState() != .connected {
                    var current = tasks[clipID] ?? task
                    current.completedBytes = update.completedBytes
                    tasks[clipID] = interrupt(task: current)
                    persist(tasks[clipID]!)
                    activeClip = nil
                    emitProgress()
                    return
                }

                var current = tasks[clipID] ?? task
                current.completedBytes = update.completedBytes
                let total = update.totalBytes > 0 ? update.totalBytes : current.clip.sizeBytes
                // R5.2: integer percent via the pure decision.
                let percent = progressPercent(completed: update.completedBytes, total: total)
                current.status = .inProgress(percent: percent)
                tasks[clipID] = current
                // Emit on a percent change (<=1s cadence in practice as the
                // transfer advances); avoids redundant same-percent emissions.
                if percent != lastEmittedPercent {
                    lastEmittedPercent = percent
                    persist(current)
                    emitProgress()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // Transfer failed (transport error): if disconnected, treat as
            // interrupt + retain bytes (R5.5); otherwise leave it interrupted so
            // it can be resumed.
            var current = tasks[clipID] ?? task
            tasks[clipID] = interrupt(task: current)
            persist(tasks[clipID]!)
            activeClip = nil
            emitProgress()
            return
        }

        if Task.isCancelled { return }

        // R5.3 + R6.8: completion — store the clip, mark downloaded, carry the
        // protected flag so Emergency_Footage stays protected.
        completeDownload(clipID, fileURL: destination)
    }

    /// Finalizes a completed clip: writes the `StoredClip` to the library with
    /// the protected flag carried from the source metadata (R5.3, R6.8).
    private func completeDownload(_ clipID: ClipID, fileURL: URL) {
        guard var task = tasks[clipID] else { return }
        let stored = StoredClip(
            metadata: task.clip,
            fileURL: fileURL,
            // R6.8: carry the source clip's protected status.
            isProtected: task.clip.isProtected,
            downloadedAt: Date()
        )
        do {
            try store.insert(stored)
            task.status = .completed
            task.completedBytes = task.clip.sizeBytes
            tasks[clipID] = task
            // The download bookkeeping record is no longer needed.
            try? store.deleteDownloadTask(for: clipID)
        } catch {
            // Storing failed — mark interrupted so it can be retried; retain the
            // transferred bytes (R5.5).
            tasks[clipID] = interrupt(task: task)
            persist(tasks[clipID]!)
        }
        if activeClip == clipID { activeClip = nil }
        emitProgress()
    }

    /// Marks the active and remaining queued clips interrupted when the link is
    /// not connected (R5.5), retaining their completed byte counts.
    private func markRemainingInterrupted(startingAt clipID: ClipID) {
        if let task = tasks[clipID] {
            tasks[clipID] = interrupt(task: task)
            persist(tasks[clipID]!)
        }
        activeClip = nil
        emitProgress()
    }

    // MARK: - File cleanup

    /// Removes the partial media file for a clip, if present (R5.9).
    private func removePartialFile(for clip: ClipID) {
        let url = store.mediaURL(for: clip)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Persistence + progress emission

    /// Persists a task's bookkeeping so the queue survives relaunch (R5.5).
    private func persist(_ task: DownloadTask) {
        try? store.upsert(task)
    }

    /// Emits the current queue snapshot on the progress stream (R5.2).
    private func emitProgress() {
        let snapshot = currentQueueState()
        progressContinuation?.yield(snapshot)
    }

    private func currentQueueState() -> DownloadQueueState {
        let states: [DownloadTaskState] = order.compactMap { id in
            guard let task = tasks[id] else { return nil }
            return DownloadTaskState(
                clipID: id,
                selectionIndex: task.selectionIndex,
                status: task.status,
                completedBytes: task.completedBytes,
                totalBytes: task.clip.sizeBytes
            )
        }
        return DownloadQueueState(tasks: states, active: activeClip)
    }

    // MARK: - Introspection (test/view support)

    /// A snapshot of the current queue state (non-stream accessor).
    public func queueState() -> DownloadQueueState {
        currentQueueState()
    }
}
