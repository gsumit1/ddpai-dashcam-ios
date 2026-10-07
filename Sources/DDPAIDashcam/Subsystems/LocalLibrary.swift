// Local_Library
//
// Task 12.1: the `LocalLibrary` protocol and its concrete implementation over
// the `LibraryStore` persistence layer.
//
// Design reference: design.md → Components and Interfaces → Local_Library.
// Responsibilities and the acceptance criteria they satisfy:
//   - allClips(): return stored clips sorted descending by recording start
//     timestamp (R7.2). `LibraryStore.allClips()` already applies that ordering.
//   - contains(_:): whether a clip is in the Local_Library (R7.1 support).
//   - delete(_:): remove a clip's metadata and media file; on failure retain the
//     clip and surface a user-facing message (R7.4, R7.5).
//   - fileURL(for:): the on-device media URL for a stored clip, else nil.
//   - everything here works regardless of Connection_State (R7.1), because all
//     I/O is local (SQLite + app-container files).
//
// Share and photo-library export are handled at the view layer via the iOS
// share sheet / Photos APIs (R7.6–R7.8) and are intentionally not part of this
// subsystem. An empty-state consideration (R7.3) is exposed via `isEmpty()` for
// the view model to render the empty-library message.

import Foundation

// MARK: - Errors

/// Errors surfaced by `LocalLibrary`.
public enum LocalLibraryError: Error, Equatable {
    /// Deleting a clip failed; the clip is retained and `message` is a
    /// user-facing deletion-failure message (R7.5).
    case deletionFailed(clipID: ClipID, message: String)
}

/// User-facing strings surfaced by `LocalLibrary`. Kept here so the subsystem
/// owns the semantics; the view layer renders them verbatim.
public enum LocalLibraryMessage {
    /// R7.3 — the Local_Library has no downloaded clips.
    public static let empty =
        "No downloaded clips yet. Download clips from the camera to view them offline."
    /// R7.5 — a delete operation failed; the clip was retained.
    public static func deletionFailed(_ clipID: ClipID) -> String {
        "Could not delete the clip. It is still in your library."
    }
}

// MARK: - Protocol

/// Local_Library interface: offline access to downloaded clips (R7.1). All
/// operations are available regardless of Connection_State.
public protocol LocalLibrary {
    /// All stored clips sorted descending by recording start timestamp (R7.2).
    func allClips() async -> [StoredClip]

    /// Whether a clip with the given id is in the Local_Library.
    func contains(_ clip: ClipID) async -> Bool

    /// Deletes a clip's metadata and media file. On failure the clip is retained
    /// and `LocalLibraryError.deletionFailed` is thrown with a message (R7.4,
    /// R7.5).
    func delete(_ clip: ClipID) async throws

    /// The on-device media file URL for a stored clip, or nil if the clip is not
    /// in the library.
    func fileURL(for clip: ClipID) async -> URL?

    /// Whether the Local_Library is empty, for the empty-state message (R7.3).
    func isEmpty() async -> Bool
}

// MARK: - Concrete implementation

/// Concrete `LocalLibrary` over a `LibraryStore`. Works fully offline since the
/// backing store is on-device SQLite + app-container files (R7.1).
public final class StoredClipLibrary: LocalLibrary {

    private let store: LibraryStore
    private let fileManager: FileManager

    public init(store: LibraryStore, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    // MARK: - Reads

    public func allClips() async -> [StoredClip] {
        // R7.2: LibraryStore.allClips() already orders by start timestamp
        // descending (ties broken by id descending) for a deterministic order.
        (try? store.allClips()) ?? []
    }

    public func contains(_ clip: ClipID) async -> Bool {
        (try? store.contains(clip)) ?? false
    }

    public func fileURL(for clip: ClipID) async -> URL? {
        // Only report a URL when the clip is actually stored; mediaURL(for:)
        // itself does not imply presence.
        guard let stored = try? store.clip(for: clip) else { return nil }
        return stored.fileURL
    }

    public func isEmpty() async -> Bool {
        await allClips().isEmpty
    }

    // MARK: - Delete (R7.4, R7.5)

    public func delete(_ clip: ClipID) async throws {
        // Resolve the media file location before touching the metadata so we can
        // remove both. If the clip is not present there is nothing to delete.
        guard let stored = try? store.clip(for: clip) else { return }

        do {
            // Remove the media file first; if that fails we retain the metadata
            // record so the library still reflects the (still-present) clip.
            if fileManager.fileExists(atPath: stored.fileURL.path) {
                try fileManager.removeItem(at: stored.fileURL)
            }
            // R7.4: delete only this clip's metadata record. The store's
            // single-key delete leaves every other clip intact (Property 17).
            try store.delete(clip)
        } catch {
            // R7.5: deletion failed — retain the clip and surface a message.
            throw LocalLibraryError.deletionFailed(
                clipID: clip,
                message: LocalLibraryMessage.deletionFailed(clip)
            )
        }
    }
}
