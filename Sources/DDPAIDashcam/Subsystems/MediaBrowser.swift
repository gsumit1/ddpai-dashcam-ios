// Media_Browser
//
// Task 9.1: `MediaBrowsing` protocol and the concrete `MediaBrowser` class that
// retrieves, orders, filters, and annotates the clips stored on the Camera.
//
// Design reference: design.md → Components and Interfaces → Media_Browser. The
// browser retrieves raw metadata via the HTTP control client, then applies the
// pure ordering/filtering functions from ClipLogic; downloaded and protected
// flags are joined from the LibraryStore and the clip metadata respectively.
// It observes the shared Connection_State rather than probing the link itself.
//
// Requirements covered (R3.1–R3.10, R6.1–R6.3):
//   - R3.1: on open while connected, retrieve and display the clip list within
//     15s.
//   - R3.2: show a loading indicator while retrieval is in progress.
//   - R3.3/R3.4: expose per-clip timestamp, duration, size, and type via the
//     ClipRow (formatting performed by the view using ClipLogic helpers).
//   - R3.5/R3.6: filtering by type retains descending order; empty filtered
//     result reports no-matching-clips.
//   - R3.7: order clips by recording start timestamp descending.
//   - R3.8: empty camera library reports empty + zero rows.
//   - R3.9: retrieval exceeding 15s cancels and reports failure + retry.
//   - R3.10: disconnect mid-retrieval stops and reports connection-lost + retry.
//   - R6.1: Emergency_Footage carries a protected indicator distinct from
//     unprotected.
//   - R6.2: emergency filter shows only event/locked clips.
//   - R6.3: emergency filter with no matches reports no-emergency-footage.
//
// Camera I/O funnels through `CameraProtocolAdapter.clipListRequest()` +
// `HTTPControlClient.send(_:timeout:)` + `adapter.parseClipList(_:)`.

import Combine
import Foundation

// MARK: - Timing constants

/// Fixed timing bounds taken from Requirement 3. Centralized so the subsystem
/// and its tests reference the same values.
public enum MediaBrowserTiming {
    /// Maximum time to retrieve the clip list before the retrieval fails (R3.1,
    /// R3.9).
    public static let clipListTimeout: Duration = .seconds(15)
}

// MARK: - Clip row

/// A single row presented by the Media_Browser: the camera clip metadata joined
/// with the downloaded flag from the Local_Library and the protection flag from
/// the metadata. The type/protection indicators come from the pure ClipLogic
/// mappings so the view renders observably distinct markers (R3.4, R6.1).
public struct ClipRow: Equatable {
    /// Camera-reported clip metadata (timestamp, duration, size, type) (R3.3).
    public let metadata: ClipMetadata
    /// Whether the clip already exists in the Local_Library (R5.3 join).
    public let isDownloaded: Bool

    public init(metadata: ClipMetadata, isDownloaded: Bool) {
        self.metadata = metadata
        self.isDownloaded = isDownloaded
    }

    /// Stable identifier, convenient for SwiftUI list identity.
    public var id: ClipID { metadata.id }

    /// Type indicator — event marker iff the clip type is event (R3.4). Named
    /// `typeMarker` so it does not shadow the free `typeIndicator(for:)` mapping.
    public var typeMarker: ClipTypeIndicator { typeIndicator(for: metadata) }

    /// Protection indicator — protected marker iff the clip is Emergency_Footage
    /// (event or locked) (R6.1). Named `protectionMarker` so it does not shadow
    /// the free `protectionIndicator(for:)` mapping.
    public var protectionMarker: ClipProtectionIndicator {
        protectionIndicator(for: metadata)
    }
}

// MARK: - Load state

/// Observable load state of the Media_Browser (design.md → Media_Browser).
public enum BrowserLoadState: Equatable {
    /// Retrieval in progress; the view shows a loading indicator (R3.2).
    case loading
    /// Retrieval succeeded with at least one row for the current filter.
    case loaded
    /// Nothing to show: either the camera reports no clips (R3.8) or the
    /// current filter matches no clips (R3.6, R6.3). Carries a user-facing
    /// message describing which case applies.
    case empty(message: String)
    /// Retrieval failed or timed out (R3.9). Carries a message; view offers
    /// retry.
    case failed(message: String)
    /// Connection dropped during retrieval (R3.10). Carries a message; view
    /// offers retry.
    case connectionLost(message: String)
}

// MARK: - User-facing messages

/// User-facing strings surfaced via `loadState`. Owned here so the subsystem
/// fully owns Media_Browser semantics; the view renders them verbatim.
public enum MediaBrowserMessage {
    /// R3.8 — the camera reports no stored clips.
    public static let emptyLibrary =
        "No recordings are stored on the camera."
    /// R3.6 — a type filter matched no clips.
    public static let noMatchingClips =
        "No clips match the selected filter."
    /// R6.3 — the emergency filter matched no event/locked clips.
    public static let noEmergencyFootage =
        "No emergency footage is available."
    /// R3.9 — retrieval exceeded the 15s bound.
    public static let retrievalFailed =
        "The clip list could not be loaded. Tap retry to try again."
    /// R3.10 — the connection dropped mid-retrieval.
    public static let connectionLost =
        "The camera link was lost. Tap retry to try again."
}

// MARK: - Protocol

/// The Media_Browser interface (design.md → Media_Browser).
@MainActor
public protocol MediaBrowsing: AnyObject {
    /// The rows currently displayed: ordered descending by start timestamp and
    /// filtered by the active filter, each with downloaded + protected flags
    /// (R3.3–R3.7, R6.1).
    var clips: [ClipRow] { get }

    /// The current load state (R3.2, R3.6, R3.8, R3.9, R3.10, R6.3).
    var loadState: BrowserLoadState { get }

    /// The active clip-type filter (R3.5, R3.6, R6.2).
    var filter: ClipFilter { get }

    /// Retrieves the clip list from the camera within the 15s bound (R3.1,
    /// R3.9) and applies ordering/filtering/flag joins.
    func load() async

    /// Sets the active filter and re-applies it to the already-retrieved clips,
    /// preserving descending order (R3.5, R3.6, R6.2).
    func setFilter(_ filter: ClipFilter)

    /// Re-initiates retrieval after a failed/connection-lost state (R3.9,
    /// R3.10).
    func retry() async
}

// MARK: - Concrete subsystem

/// Concrete Media_Browser. `@MainActor` so its observable state is mutated on
/// the main actor and read safely by SwiftUI view models.
@MainActor
public final class MediaBrowser: MediaBrowsing, ObservableObject {

    // MARK: Observable state

    /// Rows for the current filter, ordered descending (R3.5, R3.7).
    @Published public private(set) var clips: [ClipRow] = []

    /// Current load state (R3.2, R3.6, R3.8, R3.9, R3.10, R6.3).
    @Published public private(set) var loadState: BrowserLoadState = .loading

    /// Active clip-type filter (R3.5, R3.6, R6.2).
    @Published public private(set) var filter: ClipFilter = .all

    public var loadStatePublisher: Published<BrowserLoadState>.Publisher { $loadState }

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let client: HTTPControlClient
    private let store: LibraryStore
    private let connectionState: () -> ConnectionState

    // MARK: Internal bookkeeping

    /// All retrieved rows, ordered descending, before the active filter is
    /// applied. `setFilter` re-derives `clips` from this without re-fetching.
    private var allRows: [ClipRow] = []

    /// Creates a Media_Browser.
    ///
    /// - Parameters:
    ///   - adapter: builds the clip-list request and parses the response.
    ///   - client: executes the request with a bounded timeout.
    ///   - store: Local_Library used to join the downloaded flag per clip.
    ///   - connectionState: reads the shared Connection_State; the browser only
    ///     observes it (R3.10).
    public init(
        adapter: CameraProtocolAdapter,
        client: HTTPControlClient,
        store: LibraryStore,
        connectionState: @escaping () -> ConnectionState
    ) {
        self.adapter = adapter
        self.client = client
        self.store = store
        self.connectionState = connectionState
    }

    // MARK: - Load (R3.1, R3.2, R3.7, R3.8, R3.9, R3.10)

    public func load() async {
        // R3.10: if not connected we cannot retrieve; report connection-lost.
        guard connectionState() == .connected else {
            allRows = []
            clips = []
            loadState = .connectionLost(message: MediaBrowserMessage.connectionLost)
            return
        }

        // R3.2: show the loading indicator while retrieval is in progress.
        loadState = .loading

        let request = adapter.clipListRequest()
        let response: HTTPResponse
        do {
            // R3.1 / R3.9: bound the retrieval at 15s. The client surfaces a
            // timeout/cancellation as a thrown error.
            response = try await client.send(request, timeout: MediaBrowserTiming.clipListTimeout)
        } catch {
            // R3.10: a disconnect mid-retrieval is reported as connection-lost;
            // otherwise the retrieval failed/timed out (R3.9).
            if connectionState() != .connected {
                loadState = .connectionLost(message: MediaBrowserMessage.connectionLost)
            } else {
                loadState = .failed(message: MediaBrowserMessage.retrievalFailed)
            }
            return
        }

        // R3.10: if the link dropped while the request was in flight, stop and
        // report connection-lost rather than presenting stale data.
        guard connectionState() == .connected else {
            loadState = .connectionLost(message: MediaBrowserMessage.connectionLost)
            return
        }

        let rawClips: [ClipMetadata]
        do {
            rawClips = try adapter.parseClipList(response)
        } catch {
            loadState = .failed(message: MediaBrowserMessage.retrievalFailed)
            return
        }

        // R3.7: order descending by start timestamp (pure ClipLogic function).
        let ordered = orderByStartDescending(rawClips)
        // Join the downloaded flag from the Local_Library per clip (R5.3 join).
        allRows = ordered.map { metadata in
            ClipRow(metadata: metadata, isDownloaded: isDownloaded(metadata.id))
        }

        applyFilter()
    }

    public func setFilter(_ newFilter: ClipFilter) {
        // R3.5/R3.6/R6.2: switch filter and re-derive the visible rows from the
        // already-retrieved, already-ordered set without re-fetching.
        filter = newFilter
        // Re-applying the filter only makes sense once a retrieval has
        // succeeded; while loading/failed/connection-lost we leave that state
        // intact and let the next `load()` resolve it.
        switch loadState {
        case .loaded, .empty:
            applyFilter()
        case .loading, .failed, .connectionLost:
            break
        }
    }

    public func retry() async {
        // R3.9 / R3.10: re-initiate retrieval.
        await load()
    }

    // MARK: - Filtering + empty-state resolution (R3.5, R3.6, R3.8, R6.2, R6.3)

    /// Applies the active filter to the ordered rows and resolves the load
    /// state, distinguishing an empty camera library (R3.8) from a filter that
    /// matched nothing (R3.6, R6.3).
    private func applyFilter() {
        let metadata = allRows.map(\.metadata)
        // Pure ClipLogic filter preserves the descending order (R3.5, Property 5).
        let filteredMetadata = apply(filter: filter, to: metadata)
        let filteredIDs = Set(filteredMetadata.map(\.id))
        clips = allRows.filter { filteredIDs.contains($0.id) }

        if clips.isEmpty {
            loadState = .empty(message: emptyMessage())
        } else {
            loadState = .loaded
        }
    }

    /// Chooses the empty-state message: the empty-library message when the
    /// camera reported no clips at all (R3.8); otherwise the filter-specific
    /// no-matches message — the emergency-footage variant for the emergency
    /// filter (R6.3), the generic no-matching variant otherwise (R3.6).
    private func emptyMessage() -> String {
        if allRows.isEmpty {
            return MediaBrowserMessage.emptyLibrary
        }
        switch filter {
        case .emergency:
            return MediaBrowserMessage.noEmergencyFootage
        case .all, .normal, .event:
            return MediaBrowserMessage.noMatchingClips
        }
    }

    // MARK: - Local_Library join

    /// Whether a clip exists in the Local_Library; a store failure is treated as
    /// not-downloaded so a transient persistence error never hides a clip.
    private func isDownloaded(_ id: ClipID) -> Bool {
        (try? store.contains(id)) ?? false
    }
}
