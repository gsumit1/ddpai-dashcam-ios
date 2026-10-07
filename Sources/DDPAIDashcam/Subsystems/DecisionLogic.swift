// DecisionLogic
//
// Pure decision and arithmetic logic for the subsystem services. Implemented in
// task 3.1.
//
// Layer: domain logic with NO I/O. Every function here is a pure function of its
// inputs so the property-based tests (Properties 1, 2, 8, 9, 10, 11, 12, 13, 14,
// 18, 19, 20, 21, 22) can drive them cheaply and deterministically. These
// functions back Connection_Manager model support / reconnect (R1.6, R1.8, R1.9),
// Media_Player seek / source selection (R4.2, R4.6, R4.7), Download_Manager
// progress / queue / interrupt / resume / storage (R5.2, R5.4–R5.8), and
// Settings_Controller availability / optimistic-with-revert / reconcile / toggle
// (R6.5–R6.7, R8.4–R8.6, R9.4, R9.5, R10.3–R10.6, R11.3, R11.4, R11.6, R11.7,
// R12.2–R12.4).

import Foundation

// MARK: - Property 1: Camera model support decision (R1.6)

/// Decides whether a camera model identifier is supported.
///
/// The session is treated as supported if and only if `model` is a member of
/// the adapter's `supportedModels` set; any non-member is unsupported
/// (Property 1).
public func isModelSupported(_ model: String, in supportedModels: Set<String>) -> Bool {
    supportedModels.contains(model)
}

// MARK: - Property 2: Bounded retry (R1.8, R1.9, R12.2)

/// Outcome of a bounded retry loop.
public enum RetryOutcome: Equatable {
    /// Some attempt within the limit succeeded, on the given 1-based attempt number.
    case succeeded(attempt: Int)
    /// Every attempt (up to `maxAttempts`) failed.
    case failed(attempts: Int)
}

/// Runs a bounded retry loop over at most `maxAttempts` attempts.
///
/// `attempt` is invoked with the 1-based attempt number and returns whether that
/// attempt succeeded. The loop performs at most `maxAttempts` attempts, stops
/// immediately on the first success, and reports `.succeeded` if and only if some
/// attempt within the limit succeeded; otherwise `.failed` (Property 2).
///
/// `maxAttempts` is parameterized (default 3, matching R1.8). A non-positive
/// `maxAttempts` performs no attempts and fails with zero attempts.
public func retryLoop(maxAttempts: Int = 3, attempt: (Int) -> Bool) -> RetryOutcome {
    guard maxAttempts > 0 else { return .failed(attempts: 0) }
    var n = 0
    while n < maxAttempts {
        n += 1
        if attempt(n) {
            return .succeeded(attempt: n)
        }
    }
    return .failed(attempts: maxAttempts)
}

// MARK: - Property 8: Clamp into a supported range (R4.2, R11.4)

/// Clamps a value into the inclusive range `min...max` (requires `min <= max`).
///
/// The result is never below `range.lowerBound`, never above `range.upperBound`,
/// and equal to `value` when it already lies within the range (Property 8).
/// Governs playback seek (`0...duration`) and parking sensitivity level.
public func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    if value < range.lowerBound { return range.lowerBound }
    if value > range.upperBound { return range.upperBound }
    return value
}

// MARK: - Property 9: Playback source selection (R4.6, R4.7)

/// The source chosen to play a clip.
public enum PlaybackSource: Equatable {
    /// Play the Local_Library copy at the given file URL.
    case local(URL)
    /// Stream the clip from the connected camera.
    case stream
    /// Neither local nor streamable; the clip cannot be played.
    case unavailable
}

/// Selects the playback source for a clip.
///
/// Local presence takes precedence: if `localFileURL` is non-nil the local copy
/// is used; otherwise, if `connectionState` is `.connected` the camera stream is
/// used; otherwise the clip is unavailable (Property 9).
public func playbackSource(
    for localFileURL: URL?,
    connectionState: ConnectionState,
    isLocal: Bool
) -> PlaybackSource {
    if isLocal, let url = localFileURL {
        return .local(url)
    }
    if connectionState == .connected {
        return .stream
    }
    return .unavailable
}

// MARK: - Property 10: Download progress percent (R5.2)

/// Computes an integer download-progress percent in `0...100`.
///
/// Requires `0 <= completed <= total`. For `total > 0` the result is
/// `floor(completed * 100 / total)`, which is in `0...100`, non-decreasing as
/// `completed` grows, and equals 100 if and only if `completed == total`
/// (Property 10). A non-positive `total` yields 0.
public func progressPercent(completed: Int64, total: Int64) -> Int {
    guard total > 0 else { return 0 }
    let clampedCompleted = clamp(completed, to: 0...total)
    return Int((clampedCompleted * 100) / total)
}

// MARK: - Property 11: Download queue order and cap (R5.4)

/// The default maximum number of clips the download queue accepts (R5.4).
public let defaultQueueCap: Int = 100

/// Produces the processing order for a selection of clips.
///
/// The result preserves the selection order exactly; a selection exceeding `cap`
/// is truncated to the first `cap` clips, still preserving the relative order of
/// the retained clips (Property 11). The default cap is 100.
public func enqueueOrder<T>(_ selection: [T], cap: Int = defaultQueueCap) -> [T] {
    guard cap >= 0 else { return [] }
    guard selection.count > cap else { return selection }
    return Array(selection.prefix(cap))
}

// MARK: - Property 12: Interruption retains completed bytes (R5.5)

/// Transitions an in-progress download task to the interrupted status while
/// retaining its completed byte count unchanged (Property 12).
///
/// The retained `completedBytes` and the `completedBytes` carried by the
/// `.interrupted` status both equal the task's existing `completedBytes` (N).
public func interrupt(task: DownloadTask) -> DownloadTask {
    var result = task
    result.status = .interrupted(completedBytes: task.completedBytes)
    result.completedBytes = task.completedBytes
    return result
}

// MARK: - Property 13: Resume from retained offset only when connected (R5.6, R5.7)

/// The decision produced when resuming an interrupted download.
public enum ResumeDecision: Equatable {
    /// Issue a transfer request starting at the given byte offset.
    case request(fromByte: Int64)
    /// Stay interrupted; no transfer request is issued.
    case stayInterrupted
}

/// Decides whether and how to resume an interrupted download.
///
/// If `connectionState` is `.connected`, resuming issues a transfer request
/// starting at the retained completed-byte offset N (so `N + remaining == T`
/// where T is the task's total). If not connected, the task stays interrupted
/// with no request issued (Property 13).
///
/// `task.completedBytes` is the retained offset N. The task's status should be
/// `.interrupted`; the decision uses `completedBytes` as the authoritative N.
public func resumeRequest(task: DownloadTask, connectionState: ConnectionState) -> ResumeDecision {
    guard connectionState == .connected else { return .stayInterrupted }
    return .request(fromByte: task.completedBytes)
}

// MARK: - Property 14: Storage sufficiency with reserve margin (R5.8)

/// The free-storage reserve the Download_Manager keeps beyond a clip's size:
/// 50 MB (binary megabytes), per R5.8.
public let storageReserveBytes: Int64 = 50 * 1_024 * 1_024

/// Decides whether there is sufficient storage to download a clip.
///
/// Proceeds if and only if `available >= clipSize + reserve` (default reserve is
/// 50 MB). The arithmetic is the sole gate used by the download pre-check
/// (Property 14).
public func hasSufficientStorage(
    available: Int64,
    clipSize: Int64,
    reserve: Int64 = storageReserveBytes
) -> Bool {
    available >= clipSize + reserve
}

// MARK: - Property 18: Settings control availability tracks connection (R8.5, R10.6, R11.7)

/// Computes a settings control's availability from the connection state.
///
/// Availability is `.enabled` if and only if `connectionState` is `.connected`;
/// any non-connected state yields `.disabledConnectionRequired` so no write is
/// issued while not connected (Property 18).
public func controlAvailability(for connectionState: ConnectionState) -> SettingAvailability {
    connectionState == .connected ? .enabled : .disabledConnectionRequired
}

// MARK: - Property 19: A pending write disables its control (R8.6)

/// Returns the availability of a control while a write is pending.
///
/// While pending the control is `.pending` (disabled); it returns to `.enabled`
/// only once a terminal outcome is observed. When `isPending` is false the
/// availability falls back to the connection-derived availability (Property 19).
public func pendingDisable(_ isPending: Bool, connectionState: ConnectionState = .connected) -> SettingAvailability {
    isPending ? .pending : controlAvailability(for: connectionState)
}

// MARK: - Property 20: Apply on acceptance, revert otherwise (R6.5, R6.7, R8.4, R9.4, R9.5, R10.4, R10.5, R11.3, R11.6, R12.4)

/// Resolves the displayed value after a write, given the previously displayed
/// value and the write outcome.
///
/// If the outcome is `.accepted(V)` the displayed value becomes V; for
/// `.rejected`, `.timedOut`, or `.connectionLost` the displayed value reverts to
/// `previous`. The displayed value is never left on an unconfirmed optimistic
/// value (Property 20).
public func applyOrRevert(previous: SettingValue?, outcome: WriteOutcome) -> SettingValue? {
    switch outcome {
    case .accepted(let value):
        return value
    case .rejected, .timedOut, .connectionLost:
        return previous
    }
}

// MARK: - Property 21: Display converges to camera-reported value (R12.3)

/// Reconciles a displayed setting value with the camera-reported value.
///
/// The camera is the source of truth, so the result is always
/// `cameraReported` regardless of what was displayed (Property 21).
public func reconcile(displayed: SettingValue?, cameraReported: SettingValue?) -> SettingValue? {
    cameraReported
}

// MARK: - Property 22: Audio recording toggle inverts and round-trips (R10.3)

/// Inverts a boolean audio-recording state.
///
/// A single toggle inverts the state; two consecutive toggles return it to the
/// original value (Property 22).
public func toggle(_ value: Bool) -> Bool {
    !value
}
