// Persistence
//
// LibraryStore (SQLite via GRDB) for clip metadata and download bookkeeping,
// with media files kept in the app container (task 6.1).
//
// Layer: local persistence reached through a LibraryStore abstraction.
//
// The Local_Library works fully offline (R7.1): all reads and writes here go
// to the on-device SQLite database and the app-container media directory, with
// no dependency on Connection_State.
//
// Design references (design.md → Persistence Schema):
//   - `stored_clip`   table: id (PK), start_timestamp, duration_ms, size_bytes,
//                            type, is_protected, file_relative_path, downloaded_at.
//   - `download_task` table: clip_id (PK), status, completed_bytes, selection_index.
//   - Media files live in `Application Support/clips/<id>.mp4`; only the RELATIVE
//     path is persisted so records survive container path changes.

import Foundation
import GRDB

// MARK: - LibraryStore protocol

/// Local persistence abstraction for the Local_Library and the resumable
/// download queue. Kept as a protocol so subsystems (Local_Library,
/// Download_Manager, Media_Player) depend on an interface that can be mocked in
/// tests. All operations are available regardless of Connection_State (R7.1).
public protocol LibraryStore: AnyObject {

    // Stored clips (Local_Library)

    /// Inserts or replaces a stored clip. Called on download completion to add
    /// the clip to the Local_Library and mark it downloaded (R5.3), carrying the
    /// source clip's protected flag so Emergency_Footage stays protected (R6.8).
    func insert(_ clip: StoredClip) throws

    /// All stored clips ordered by recording start timestamp, most recent first
    /// (R7.2). Ties are broken by id descending for a deterministic total order.
    func allClips() throws -> [StoredClip]

    /// The stored clip for an id, or nil if the clip is not in the library.
    func clip(for id: ClipID) throws -> StoredClip?

    /// True iff a clip with the given id exists in the Local_Library.
    func contains(_ id: ClipID) throws -> Bool

    /// Deletes a single stored clip's metadata record (R7.4). Removing only the
    /// targeted record leaves every other stored clip intact (Property 17).
    func delete(_ id: ClipID) throws

    // Download tasks (resumable queue bookkeeping)

    /// Inserts or updates the bookkeeping record for a download task, preserving
    /// the retained completed-byte count across launches (R5.5).
    func upsert(_ task: DownloadTask) throws

    /// All persisted download tasks ordered by their selection index (R5.4).
    func allDownloadTasks() throws -> [DownloadTask]

    /// The persisted download task for a clip id, or nil if none is stored.
    func downloadTask(for clipID: ClipID) throws -> DownloadTask?

    /// Deletes the bookkeeping record for a download task.
    func deleteDownloadTask(for clipID: ClipID) throws

    // Media file locations

    /// Absolute URL where the media file for a clip id lives in the app
    /// container (`Application Support/clips/<id>.mp4`). Does not imply the file
    /// or a metadata record exists; callers that need presence should use
    /// `contains(_:)` or `clip(for:)`.
    func mediaURL(for id: ClipID) -> URL
}

// MARK: - Column encodings

/// `ClipType` ⇄ stored string column.
extension ClipType {
    var storageValue: String {
        switch self {
        case .normal: return "normal"
        case .event: return "event"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "normal": self = .normal
        case "event": self = .event
        default: return nil
        }
    }
}

/// `Duration` ⇄ whole-millisecond integer column. Milliseconds give enough
/// precision for clip lengths while staying a simple integer column.
extension Duration {
    var milliseconds: Int64 {
        let c = components
        return c.seconds * 1_000 + Int64(c.attoseconds / 1_000_000_000_000_000)
    }

    init(milliseconds: Int64) {
        let seconds = milliseconds / 1_000
        let remainderMillis = milliseconds % 1_000
        let attoseconds = remainderMillis * 1_000_000_000_000_000
        self = .init(secondsComponent: seconds, attosecondsComponent: attoseconds)
    }
}

// MARK: - GRDB record rows

/// GRDB row mapping for the `stored_clip` table. Kept internal to the
/// persistence layer; the public API exchanges domain `StoredClip` values.
private struct StoredClipRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "stored_clip"

    var id: String
    var startTimestamp: Date
    var durationMs: Int64
    var sizeBytes: Int64
    var type: String
    var isProtected: Bool
    var fileRelativePath: String
    var downloadedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case startTimestamp = "start_timestamp"
        case durationMs = "duration_ms"
        case sizeBytes = "size_bytes"
        case type
        case isProtected = "is_protected"
        case fileRelativePath = "file_relative_path"
        case downloadedAt = "downloaded_at"
    }
}

/// GRDB row mapping for the `download_task` table. The lifecycle status is
/// flattened into a discriminator plus the operands the status carries, so the
/// row survives relaunch and reconstructs the exact `DownloadStatus` case.
private struct DownloadTaskRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "download_task"

    // Clip metadata (download tasks hold the full clip so the queue can be
    // rebuilt across launches without the camera being reachable).
    var clipId: String
    var clipStartTimestamp: Date
    var clipDurationMs: Int64
    var clipSizeBytes: Int64
    var clipType: String
    var clipIsLocked: Bool

    // Task bookkeeping.
    var status: String
    var statusPercent: Int?
    var statusCompletedBytes: Int64?
    var statusRequired: Int64?
    var statusAvailable: Int64?
    var completedBytes: Int64
    var selectionIndex: Int

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case clipStartTimestamp = "clip_start_timestamp"
        case clipDurationMs = "clip_duration_ms"
        case clipSizeBytes = "clip_size_bytes"
        case clipType = "clip_type"
        case clipIsLocked = "clip_is_locked"
        case status
        case statusPercent = "status_percent"
        case statusCompletedBytes = "status_completed_bytes"
        case statusRequired = "status_required"
        case statusAvailable = "status_available"
        case completedBytes = "completed_bytes"
        case selectionIndex = "selection_index"
    }
}

// MARK: - DownloadStatus encoding

private extension DownloadStatus {
    /// Discriminator string stored in `download_task.status`.
    var discriminator: String {
        switch self {
        case .queued: return "queued"
        case .inProgress: return "in_progress"
        case .interrupted: return "interrupted"
        case .completed: return "completed"
        case .canceled: return "canceled"
        case .failedInsufficientStorage: return "failed_insufficient_storage"
        }
    }
}

// MARK: - GRDB-backed implementation

/// Errors raised by `GRDBLibraryStore` for conditions outside GRDB's own
/// error domain (e.g. a corrupt status row).
public enum LibraryStoreError: Error, Equatable {
    /// A persisted row held a value that no longer maps to a known enum case.
    case corruptRecord(String)
}

/// GRDB-backed `LibraryStore` using GRDB 7.x. Owns the SQLite database and the
/// media directory under `Application Support`. Thread-safe through GRDB's
/// `DatabaseQueue` serialization.
public final class GRDBLibraryStore: LibraryStore {

    private let dbQueue: DatabaseQueue
    /// Directory under the app container that holds the media files.
    /// Only relative paths (relative to this directory) are persisted (R7.*).
    private let clipsDirectory: URL

    /// Opens (or creates) the database at `databaseURL` and ensures the media
    /// directory `clipsDirectory` exists, then runs migrations.
    ///
    /// - Parameters:
    ///   - databaseURL: SQLite file location (defaults to
    ///     `Application Support/library.sqlite`).
    ///   - clipsDirectory: media directory (defaults to
    ///     `Application Support/clips`); media files are `<id>.mp4` within it.
    public init(
        databaseURL: URL? = nil,
        clipsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let appSupport = try Self.applicationSupportDirectory(fileManager: fileManager)

        let resolvedDBURL = databaseURL ?? appSupport.appendingPathComponent("library.sqlite")
        let resolvedClipsDir = clipsDirectory ?? appSupport.appendingPathComponent("clips", isDirectory: true)

        // Ensure parent directories exist before opening the database / writing media.
        try fileManager.createDirectory(
            at: resolvedDBURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: resolvedClipsDir,
            withIntermediateDirectories: true
        )

        self.clipsDirectory = resolvedClipsDir
        self.dbQueue = try DatabaseQueue(path: resolvedDBURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Application Support resolution

    private static func applicationSupportDirectory(fileManager: FileManager) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    // MARK: Migrations

    /// Database schema migrator defining the `stored_clip` and `download_task`
    /// tables. Registered migrations are append-only so existing databases
    /// upgrade cleanly across launches.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createStoredClip") { db in
            try db.create(table: "stored_clip") { t in
                t.column("id", .text).primaryKey()
                t.column("start_timestamp", .datetime).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("size_bytes", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("is_protected", .boolean).notNull()
                t.column("file_relative_path", .text).notNull()
                t.column("downloaded_at", .datetime).notNull()
            }
            // Supports the descending-start-timestamp ordering query (R7.2).
            try db.create(
                index: "idx_stored_clip_start_timestamp",
                on: "stored_clip",
                columns: ["start_timestamp"]
            )
        }

        migrator.registerMigration("createDownloadTask") { db in
            try db.create(table: "download_task") { t in
                t.column("clip_id", .text).primaryKey()
                t.column("clip_start_timestamp", .datetime).notNull()
                t.column("clip_duration_ms", .integer).notNull()
                t.column("clip_size_bytes", .integer).notNull()
                t.column("clip_type", .text).notNull()
                t.column("clip_is_locked", .boolean).notNull()
                t.column("status", .text).notNull()
                t.column("status_percent", .integer)
                t.column("status_completed_bytes", .integer)
                t.column("status_required", .integer)
                t.column("status_available", .integer)
                t.column("completed_bytes", .integer).notNull()
                t.column("selection_index", .integer).notNull()
            }
        }

        return migrator
    }

    // MARK: Media file locations

    public func mediaURL(for id: ClipID) -> URL {
        clipsDirectory.appendingPathComponent(Self.relativePath(for: id))
    }

    /// Relative path (relative to `clipsDirectory`) persisted for a clip id:
    /// `<id>.mp4`. Keeping it relative means stored records survive a change in
    /// the app container's absolute path.
    private static func relativePath(for id: ClipID) -> String {
        "\(id).mp4"
    }

    /// Resolves a persisted relative path back to an absolute URL under the
    /// current media directory.
    private func absoluteURL(forRelativePath relativePath: String) -> URL {
        clipsDirectory.appendingPathComponent(relativePath)
    }

    // MARK: Stored clips

    public func insert(_ clip: StoredClip) throws {
        // Persist the file location as a path relative to the media directory so
        // the record is robust to container-path changes. If the file lives at
        // the conventional `<id>.mp4` location we store that; otherwise we store
        // the last path component as the relative path.
        let relativePath = Self.relativePath(for: clip.metadata.id)
        let row = StoredClipRow(
            id: clip.metadata.id,
            startTimestamp: clip.metadata.startTimestamp,
            durationMs: clip.metadata.duration.milliseconds,
            sizeBytes: clip.metadata.sizeBytes,
            type: clip.metadata.type.storageValue,
            isProtected: clip.isProtected,
            fileRelativePath: relativePath,
            downloadedAt: clip.downloadedAt
        )
        try dbQueue.write { db in
            try row.save(db)
        }
    }

    public func allClips() throws -> [StoredClip] {
        let rows = try dbQueue.read { db in
            try StoredClipRow
                .order(
                    Column("start_timestamp").desc,
                    Column("id").desc
                )
                .fetchAll(db)
        }
        return try rows.map { try storedClip(from: $0) }
    }

    public func clip(for id: ClipID) throws -> StoredClip? {
        let row = try dbQueue.read { db in
            try StoredClipRow.fetchOne(db, key: id)
        }
        return try row.map { try storedClip(from: $0) }
    }

    public func contains(_ id: ClipID) throws -> Bool {
        try dbQueue.read { db in
            try StoredClipRow.filter(key: id).fetchCount(db) > 0
        }
    }

    public func delete(_ id: ClipID) throws {
        _ = try dbQueue.write { db in
            try StoredClipRow.deleteOne(db, key: id)
        }
    }

    private func storedClip(from row: StoredClipRow) throws -> StoredClip {
        guard let type = ClipType(storageValue: row.type) else {
            throw LibraryStoreError.corruptRecord("unknown clip type \"\(row.type)\" for clip \(row.id)")
        }
        let metadata = ClipMetadata(
            id: row.id,
            startTimestamp: row.startTimestamp,
            duration: Duration(milliseconds: row.durationMs),
            sizeBytes: row.sizeBytes,
            type: type,
            // `isLocked` is reconstructed so that `isProtected` matches the
            // persisted protected flag (R6.8). Event footage is always
            // protected; for non-event clips, the lock flag carries protection.
            isLocked: row.isProtected && type != .event
        )
        return StoredClip(
            metadata: metadata,
            fileURL: absoluteURL(forRelativePath: row.fileRelativePath),
            isProtected: row.isProtected,
            downloadedAt: row.downloadedAt
        )
    }

    // MARK: Download tasks

    public func upsert(_ task: DownloadTask) throws {
        let row = downloadTaskRow(from: task)
        try dbQueue.write { db in
            try row.save(db)
        }
    }

    public func allDownloadTasks() throws -> [DownloadTask] {
        let rows = try dbQueue.read { db in
            try DownloadTaskRow
                .order(Column("selection_index").asc)
                .fetchAll(db)
        }
        return try rows.map { try downloadTask(from: $0) }
    }

    public func downloadTask(for clipID: ClipID) throws -> DownloadTask? {
        let row = try dbQueue.read { db in
            try DownloadTaskRow.fetchOne(db, key: clipID)
        }
        return try row.map { try downloadTask(from: $0) }
    }

    public func deleteDownloadTask(for clipID: ClipID) throws {
        _ = try dbQueue.write { db in
            try DownloadTaskRow.deleteOne(db, key: clipID)
        }
    }

    private func downloadTaskRow(from task: DownloadTask) -> DownloadTaskRow {
        var statusPercent: Int?
        var statusCompletedBytes: Int64?
        var statusRequired: Int64?
        var statusAvailable: Int64?

        switch task.status {
        case .queued, .completed, .canceled:
            break
        case let .inProgress(percent):
            statusPercent = percent
        case let .interrupted(completedBytes):
            // Retain the completed-byte count across launches (R5.5).
            statusCompletedBytes = completedBytes
        case let .failedInsufficientStorage(required, available):
            statusRequired = required
            statusAvailable = available
        }

        return DownloadTaskRow(
            clipId: task.clip.id,
            clipStartTimestamp: task.clip.startTimestamp,
            clipDurationMs: task.clip.duration.milliseconds,
            clipSizeBytes: task.clip.sizeBytes,
            clipType: task.clip.type.storageValue,
            clipIsLocked: task.clip.isLocked,
            status: task.status.discriminator,
            statusPercent: statusPercent,
            statusCompletedBytes: statusCompletedBytes,
            statusRequired: statusRequired,
            statusAvailable: statusAvailable,
            completedBytes: task.completedBytes,
            selectionIndex: task.selectionIndex
        )
    }

    private func downloadTask(from row: DownloadTaskRow) throws -> DownloadTask {
        guard let clipType = ClipType(storageValue: row.clipType) else {
            throw LibraryStoreError.corruptRecord("unknown clip type \"\(row.clipType)\" for download task \(row.clipId)")
        }
        let clip = ClipMetadata(
            id: row.clipId,
            startTimestamp: row.clipStartTimestamp,
            duration: Duration(milliseconds: row.clipDurationMs),
            sizeBytes: row.clipSizeBytes,
            type: clipType,
            isLocked: row.clipIsLocked
        )
        let status = try Self.downloadStatus(from: row)
        return DownloadTask(
            clip: clip,
            status: status,
            completedBytes: row.completedBytes,
            selectionIndex: row.selectionIndex
        )
    }

    private static func downloadStatus(from row: DownloadTaskRow) throws -> DownloadStatus {
        switch row.status {
        case "queued":
            return .queued
        case "in_progress":
            return .inProgress(percent: row.statusPercent ?? 0)
        case "interrupted":
            return .interrupted(completedBytes: row.statusCompletedBytes ?? row.completedBytes)
        case "completed":
            return .completed
        case "canceled":
            return .canceled
        case "failed_insufficient_storage":
            return .failedInsufficientStorage(
                required: row.statusRequired ?? 0,
                available: row.statusAvailable ?? 0
            )
        default:
            throw LibraryStoreError.corruptRecord("unknown download status \"\(row.status)\" for task \(row.clipId)")
        }
    }
}
