// ClipLogic
//
// Pure formatting, ordering, and filtering logic over ClipMetadata.
// Implemented in task 2.1.
//
// Layer: domain logic with NO I/O. Every function here is a pure function of
// its inputs so the property-based tests (Properties 4, 5, 6, 7) can drive it
// cheaply and deterministically. These functions back Media_Browser ordering /
// filtering / indicators (R3.3–R3.7, R6.1, R6.2), Local_Library ordering
// (R7.2), and Media_Player duration/size display (R4.3).

import Foundation

// MARK: - Duration & size formatting (Property 7, R3.3, R4.3)

/// Formats a non-negative duration as hours:minutes:seconds.
///
/// The whole-second count is truncated (fractional seconds are dropped) so that
/// `parseDurationSeconds(formatDuration(d))` round-trips to the same whole-second
/// count for any non-negative duration (Property 7). Hours are not zero-padded
/// and have no upper bound; minutes and seconds are always two digits.
///
/// Examples: `0s -> "0:00:00"`, `75s -> "0:01:15"`, `3661s -> "1:01:01"`.
///
/// Negative durations are treated as zero; duration/size here are always
/// non-negative per the data model and the property statement.
public func formatDuration(_ duration: Duration) -> String {
    let totalSeconds = max(0, wholeSeconds(of: duration))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d:%02d", hours, minutes, seconds)
}

/// Parses an `H:M:S` string produced by `formatDuration` back into a whole-second
/// count. Returns `nil` if the string is not in the expected three-component
/// `hours:minutes:seconds` form. This is the inverse used by Property 7's
/// round-trip check.
public func parseDurationSeconds(_ string: String) -> Int64? {
    let parts = string.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let hours = Int64(parts[0]),
          let minutes = Int64(parts[1]),
          let seconds = Int64(parts[2]),
          hours >= 0, minutes >= 0, seconds >= 0
    else {
        return nil
    }
    return hours * 3600 + minutes * 60 + seconds
}

/// The whole-second count of a duration, truncated toward zero.
public func wholeSeconds(of duration: Duration) -> Int64 {
    duration.components.seconds
}

/// Number of bytes in one megabyte (binary / MiB), the fixed divisor used for
/// size display.
public let bytesPerMegabyte: Int64 = 1_048_576

/// Converts a byte size to megabytes using the fixed binary divisor
/// (1,048,576 bytes per MB) under a fixed rounding rule (round half away from
/// zero via `.rounded()`). The result is never negative: negative inputs are
/// treated as zero (Property 7).
public func megabytes(fromBytes bytes: Int64) -> Double {
    guard bytes > 0 else { return 0 }
    let mb = Double(bytes) / Double(bytesPerMegabyte)
    return (mb * 100).rounded() / 100
}

// MARK: - Ordering (Property 4, R3.7, R7.2)

/// Orders clips by recording start timestamp, most recent first.
///
/// The result is non-increasing by `startTimestamp`: every clip's start
/// timestamp is greater than or equal to the next clip's (Property 4). Ties are
/// broken by `id` descending to make the ordering total and deterministic.
public func orderByStartDescending(_ clips: [ClipMetadata]) -> [ClipMetadata] {
    clips.sorted { lhs, rhs in
        if lhs.startTimestamp != rhs.startTimestamp {
            return lhs.startTimestamp > rhs.startTimestamp
        }
        return lhs.id > rhs.id
    }
}

// MARK: - Filtering (Property 5, R3.5, R3.6, R6.2)

/// True iff a single clip matches a filter. The predicate drives both filtering
/// and the soundness/completeness checks in Property 5.
///
/// - `all`: every clip matches.
/// - `normal`: clips whose type is `.normal`.
/// - `event`: clips whose type is `.event`.
/// - `emergency`: protected clips (type `.event` OR locked), i.e. `isProtected`.
public func matches(_ clip: ClipMetadata, _ filter: ClipFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .normal:
        return clip.type == .normal
    case .event:
        return clip.type == .event
    case .emergency:
        return clip.isProtected
    }
}

/// Applies a filter to a clip collection, preserving the input order.
///
/// The result contains exactly the clips matching the filter — no non-matching
/// clip is included and no matching clip is omitted — and the relative order of
/// the retained clips is unchanged (Property 5). Callers that need descending
/// start-timestamp order should order first (or filter an already-ordered
/// collection), since filtering preserves whatever order it is given.
public func apply(filter: ClipFilter, to clips: [ClipMetadata]) -> [ClipMetadata] {
    clips.filter { matches($0, filter) }
}

// MARK: - Indicators (Property 6, R3.4, R6.1)

/// Type indicator shown on a clip row. The two cases are observably distinct so
/// the event marker is distinguishable from the normal marker (Property 6).
public enum ClipTypeIndicator: Equatable {
    case normal
    case event
}

/// Protection indicator shown on a clip row. The two cases are observably
/// distinct so the protected marker is distinguishable from the unprotected
/// marker (Property 6).
public enum ClipProtectionIndicator: Equatable {
    case unprotected
    case protected
}

/// Maps a clip to its type indicator: the event marker if and only if the clip
/// type is `.event` (Property 6, R3.4).
public func typeIndicator(for clip: ClipMetadata) -> ClipTypeIndicator {
    clip.type == .event ? .event : .normal
}

/// Maps a clip to its protection indicator: the protected marker if and only if
/// the clip is protected — event footage or a manually locked clip
/// (Property 6, R6.1).
public func protectionIndicator(for clip: ClipMetadata) -> ClipProtectionIndicator {
    clip.isProtected ? .protected : .unprotected
}
