// Models
//
// Core data model value types for the DDPAI dash cam companion app.
// Implemented in task 1.2.
//
// Layer: domain value types with no I/O, shared across every subsystem.
// All types are Equatable value types so pure logic and property-based tests
// can compare them directly. Field semantics mirror the Data Models section of
// design.md and the referenced acceptance criteria.

import Foundation

// MARK: - Connection

/// The single source of truth observed by every subsystem (R1.1).
///
/// Transitions: disconnected → connecting → connected; connected → interrupted
/// on link loss; interrupted → connecting (auto-reconnect) / connected / disconnected.
public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case interrupted
}

// MARK: - Clips

/// Recording category of a clip (R3.4). `event` footage is treated as
/// protected regardless of the lock flag.
public enum ClipType: Equatable {
    case normal
    case event
}

/// Stable identifier for a clip, used across the camera API and persistence.
public typealias ClipID = String

/// Camera-reported metadata for a single recorded clip.
public struct ClipMetadata: Equatable {
    /// Stable clip identifier.
    public let id: ClipID
    /// Recording start time; drives descending ordering (R3.7).
    public let startTimestamp: Date
    /// Clip length, used for H:M:S display (R3.3).
    public let duration: Duration
    /// Clip size in bytes, used for MB display (R3.3).
    public let sizeBytes: Int64
    /// Normal vs event recording (R3.4).
    public let type: ClipType
    /// Manual overwrite-protection (lock) flag.
    public let isLocked: Bool

    /// Emergency_Footage == event footage OR a manually locked clip (R6.2).
    public var isProtected: Bool { type == .event || isLocked }

    public init(
        id: ClipID,
        startTimestamp: Date,
        duration: Duration,
        sizeBytes: Int64,
        type: ClipType,
        isLocked: Bool
    ) {
        self.id = id
        self.startTimestamp = startTimestamp
        self.duration = duration
        self.sizeBytes = sizeBytes
        self.type = type
        self.isLocked = isLocked
    }
}

/// A clip downloaded into the Local_Library.
public struct StoredClip: Equatable {
    /// The source clip metadata.
    public let metadata: ClipMetadata
    /// Location of the downloaded media file in the app container.
    public let fileURL: URL
    /// Persisted protected flag, carried from the source clip at store time (R6.8).
    public let isProtected: Bool
    /// When the clip finished downloading.
    public let downloadedAt: Date

    public init(
        metadata: ClipMetadata,
        fileURL: URL,
        isProtected: Bool,
        downloadedAt: Date
    ) {
        self.metadata = metadata
        self.fileURL = fileURL
        self.isProtected = isProtected
        self.downloadedAt = downloadedAt
    }
}

/// Browser filter selection (R3.5, R3.6, R6.2).
public enum ClipFilter: Equatable {
    case all
    case normal
    case event
    case emergency
}

// MARK: - Downloads

/// Lifecycle status of a queued/active download.
public enum DownloadStatus: Equatable, Sendable {
    case queued
    /// In-progress transfer, reporting an integer percent in 0...100 (R5.2).
    case inProgress(percent: Int)
    /// Interrupted mid-transfer; retains the completed byte count for resume (R5.5).
    case interrupted(completedBytes: Int64)
    case completed
    case canceled
    /// Blocked because free storage is below the clip size plus reserve (R5.8).
    case failedInsufficientStorage(required: Int64, available: Int64)
}

/// A unit of work in the download queue.
public struct DownloadTask: Equatable {
    /// The clip to download.
    public let clip: ClipMetadata
    /// Current status.
    public var status: DownloadStatus
    /// Bytes transferred so far (retained across interruption for resume).
    public var completedBytes: Int64
    /// Position in the user's selection; preserves selection order (R5.4).
    public let selectionIndex: Int

    public init(
        clip: ClipMetadata,
        status: DownloadStatus,
        completedBytes: Int64,
        selectionIndex: Int
    ) {
        self.clip = clip
        self.status = status
        self.completedBytes = completedBytes
        self.selectionIndex = selectionIndex
    }
}

// MARK: - Settings

/// Identifies a remotely controllable camera setting.
public enum SettingKey: Equatable {
    case resolution
    case collisionSensitivity
    case audioRecording
    case parkingMode
    case parkingSensitivity
}

/// A typed setting value. The case used depends on the associated `SettingKey`.
public enum SettingValue: Equatable {
    case resolution(String)
    /// Collision / parking sensitivity level.
    case level(Int)
    /// Audio recording on/off.
    case bool(Bool)
    case parkingMode(String)
}

/// Availability of a settings control relative to connection and sync state.
public enum SettingAvailability: Equatable {
    /// Connected and ready for interaction.
    case enabled
    /// Not connected; interaction requires a camera connection.
    case disabledConnectionRequired
    /// Options/value could not be retrieved from the camera.
    case retrievalFailed
    /// A write is in flight; the control is temporarily disabled.
    case pending
}

/// The displayed state of a single setting.
public struct SettingState: Equatable {
    /// Which setting this describes.
    public let key: SettingKey
    /// Camera-reported current value, or nil when unknown/unavailable.
    public let currentValue: SettingValue?
    /// Supported options / range endpoints for the control.
    public let options: [SettingValue]
    /// Current availability of the control.
    public let availability: SettingAvailability

    public init(
        key: SettingKey,
        currentValue: SettingValue?,
        options: [SettingValue],
        availability: SettingAvailability
    ) {
        self.key = key
        self.currentValue = currentValue
        self.options = options
        self.availability = availability
    }
}

/// Terminal outcome of a settings (or clip lock) write.
public enum WriteOutcome: Equatable {
    /// Accepted; the camera applied the given value.
    case accepted(SettingValue)
    /// Explicitly rejected by the camera.
    case rejected
    /// No acknowledgement within the timeout bound.
    case timedOut
    /// Connection dropped before acknowledgement.
    case connectionLost
}
