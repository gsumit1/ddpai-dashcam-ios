// App composition root + dependency wiring
//
// Task 16.3: the composition root that instantiates `Connection_Manager`
// (owning the single shared `Connection_State`), the concrete Camera
// Communication Layer (`DDPAICameraProtocolAdapter` + `URLSessionHTTPControlClient`
// + `AVFoundationLiveStreamClient`), the `GRDBLibraryStore`, every subsystem,
// and every view model. A single `ConnectionManager` is created and shared so
// each subsystem/view model observes the one source of truth (R1.1, R7.1).
//
// Design reference: design.md → Architecture and "Connection State as Shared
// Observable". The container is the only place that knows how to assemble the
// object graph; views receive fully-formed view models.

import Combine
import Foundation

// MARK: - DependencyContainer

/// Builds and owns the shared object graph. `@MainActor` because the manager,
/// subsystems, and view models it creates are main-actor isolated.
///
/// All subsystems read the shared Connection_State through the one
/// `ConnectionManager` the container owns, so a connect / interrupt /
/// disconnect transition is observed uniformly everywhere (R1.1). The
/// `GRDBLibraryStore` is shared so the Local_Library is available regardless of
/// connection state (R7.1).
@MainActor
public final class DependencyContainer {

    // MARK: Shared singletons

    /// The concrete DDPAI adapter: the only type that knows DDPAI wire details.
    public let adapter: DDPAICameraProtocolAdapter

    /// The HTTP control channel over `URLSession`.
    public let httpClient: URLSessionHTTPControlClient

    /// The live-stream (RTSP/RTP) channel.
    public let liveStreamClient: AVFoundationLiveStreamClient

    /// On-device persistence (SQLite via GRDB) + app-container media files.
    public let store: LibraryStore

    /// The single source of truth every subsystem observes (R1.1).
    public let connectionManager: ConnectionManager

    // MARK: Subsystems

    public let livePreview: LivePreview
    public let mediaBrowser: MediaBrowser
    public let mediaPlayer: MediaPlayer
    public let downloadManager: DownloadManager
    public let localLibrary: StoredClipLibrary
    public let settingsController: SettingsController

    // MARK: Lifetime

    /// Creates the full dependency graph.
    ///
    /// - Throws: if the `GRDBLibraryStore` cannot open its database / media
    ///   directory under Application Support.
    public init(
        adapter: DDPAICameraProtocolAdapter = DDPAICameraProtocolAdapter(),
        session: URLSession = .shared,
        store: LibraryStore? = nil,
        reachability: CameraReachability = NWPathReachability()
    ) throws {
        self.adapter = adapter
        self.httpClient = URLSessionHTTPControlClient(session: session)
        self.liveStreamClient = AVFoundationLiveStreamClient()
        let resolvedStore = try store ?? GRDBLibraryStore()
        self.store = resolvedStore

        // The one Connection_Manager, owning the shared Connection_State (R1.1).
        let manager = ConnectionManager(
            adapter: adapter,
            client: httpClient,
            reachability: reachability
        )
        self.connectionManager = manager

        // Every subsystem reads the shared Connection_State via the manager so
        // they all observe the single source of truth (R1.1). The reads are
        // main-actor closures capturing the manager.
        let connectionState: @MainActor () -> ConnectionState = { manager.state }
        let sendableConnectionState: @Sendable () -> ConnectionState = {
            MainActor.assumeIsolated { manager.state }
        }

        self.livePreview = LivePreview(
            adapter: adapter,
            streamClient: liveStreamClient,
            connectionState: connectionState,
            // R2.4: a stream of Connection_State transitions, bridged from the
            // manager's `@Published state` so Live_Preview stops rendering when
            // the link leaves connected.
            connectionUpdates: {
                Self.connectionStateStream(from: manager)
            }
        )

        self.mediaBrowser = MediaBrowser(
            adapter: adapter,
            client: httpClient,
            store: resolvedStore,
            connectionState: connectionState
        )

        self.mediaPlayer = MediaPlayer(
            adapter: adapter,
            store: resolvedStore,
            connectionState: connectionState
        )

        self.downloadManager = DownloadManager(
            adapter: adapter,
            client: httpClient,
            store: resolvedStore,
            availableStorage: Self.availableStorageBytes,
            connectionState: sendableConnectionState
        )

        self.localLibrary = StoredClipLibrary(store: resolvedStore)

        self.settingsController = SettingsController(
            adapter: adapter,
            client: httpClient,
            connectionState: connectionState
        )
    }

    // MARK: - View-model factories

    /// A connection view model bound to the shared manager (R1.1).
    public func makeConnectionViewModel() -> ConnectionViewModel {
        ConnectionViewModel(manager: connectionManager)
    }

    public func makeLivePreviewViewModel() -> LivePreviewViewModel {
        LivePreviewViewModel(preview: livePreview)
    }

    public func makeMediaBrowserViewModel() -> MediaBrowserViewModel {
        MediaBrowserViewModel(browser: mediaBrowser)
    }

    public func makeMediaPlayerViewModel() -> MediaPlayerViewModel {
        MediaPlayerViewModel(player: mediaPlayer)
    }

    public func makeDownloadViewModel() -> DownloadViewModel {
        DownloadViewModel(manager: downloadManager)
    }

    public func makeLocalLibraryViewModel() -> LocalLibraryViewModel {
        LocalLibraryViewModel(library: localLibrary)
    }

    public func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(controller: settingsController)
    }

    // MARK: - Helpers

    /// Bridges the manager's `@Published state` into an `AsyncStream` of
    /// Connection_State transitions for Live_Preview (R2.4). Emits the current
    /// value immediately, then every subsequent change.
    private static func connectionStateStream(from manager: ConnectionManager) -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let cancellable = manager.statePublisher.sink { state in
                continuation.yield(state)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// Current free storage (bytes) on the app's volume, for the per-clip
    /// storage check (R5.8). Falls back to a large value if it cannot be read
    /// so downloads are not spuriously blocked. `@Sendable` + `nonisolated` so
    /// it can be passed to the `DownloadManager` actor without crossing the
    /// container's `@MainActor` isolation.
    @Sendable
    private nonisolated static func availableStorageBytes() -> Int64 {
        let fileManager = FileManager.default
        guard
            let url = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ),
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return .max
        }
        return capacity
    }
}
