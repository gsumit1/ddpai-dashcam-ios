// Connection / Live_Preview / Media_Browser view models
//
// Task 15.1: `ConnectionViewModel`, `LivePreviewViewModel`, and
// `MediaBrowserViewModel`.
//
// Design reference: design.md → Architecture (MVVM + unidirectional state).
// Each view model is a thin `@MainActor ObservableObject` presentation layer:
// it exposes `@Published` view state derived from its subsystem (and, where
// relevant, the shared Connection_State), and forwards user intents to that
// subsystem. No business logic lives here — ordering, filtering, timeouts,
// reconnection, and stream lifecycle all live in the subsystem services. Display
// strings are produced with the pure ClipLogic helpers (duration H:M:S, size MB).
//
// The view models mirror their subsystems' observable state rather than
// re-deriving it, so the view is a function of state and reacts uniformly to
// connect / interrupt / disconnect transitions.

import Combine
import Foundation

// MARK: - ConnectionViewModel (R1.1)

/// Presentation state for the connection screen. Mirrors `ConnectionManaging`'s
/// observable `Connection_State`, camera model, and status message, and forwards
/// the connect / disconnect intents (R1.1).
@MainActor
public final class ConnectionViewModel: ObservableObject {

    // MARK: Observable view state

    /// The current link status label source (R1.1). The view renders a label
    /// derived from this state.
    @Published public private(set) var state: ConnectionState

    /// The connected camera model identifier, shown once connected (R1.3).
    @Published public private(set) var cameraModel: String?

    /// Latest user-facing instruction/failure message (join instruction,
    /// connect-failure, reconnection prompt, link-lost) or nil (R1.4–R1.9).
    @Published public private(set) var statusMessage: String?

    // MARK: Dependencies

    private let manager: ConnectionManaging
    private var cancellables: Set<AnyCancellable> = []

    /// Creates a ConnectionViewModel bound to a Connection_Manager.
    ///
    /// The view model subscribes to the manager's published state so its own
    /// `@Published` properties stay in lock-step with the single source of truth
    /// (R1.1). Binding is set up only when the manager is the concrete
    /// `ConnectionManager` (which exposes the Combine publishers); the initial
    /// values are always seeded so the protocol-only case still renders.
    public init(manager: ConnectionManaging) {
        self.manager = manager
        self.state = manager.state
        self.cameraModel = manager.cameraModel
        self.statusMessage = manager.statusMessage
        bind()
    }

    private func bind() {
        guard let concrete = manager as? ConnectionManager else { return }
        concrete.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)
        concrete.$cameraModel
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.cameraModel = $0 }
            .store(in: &cancellables)
        concrete.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.statusMessage = $0 }
            .store(in: &cancellables)
    }

    // MARK: Derived display

    /// Whether a connection is currently established (convenience for the view).
    public var isConnected: Bool { state == .connected }

    /// A short status label for the current connection state (R1.1).
    public var statusLabel: String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .interrupted: return "Reconnecting…"
        }
    }

    // MARK: Intents

    /// Forwards the connect intent to the Connection_Manager (R1.1).
    public func connect() async { await manager.connect() }

    /// Forwards the disconnect intent to the Connection_Manager.
    public func disconnect() async { await manager.disconnect() }
}

// MARK: - LivePreviewViewModel (R2.3, R2.4)

/// Presentation state for the live preview screen. Mirrors `LivePreviewing`'s
/// status (which only reaches `rendering` while connected — R2.4), audio
/// availability, and mute state, and forwards open / close / mute / retry
/// intents. The subsystem owns stream lifecycle and the stop-on-interrupt rule;
/// this view model only reflects it.
@MainActor
public final class LivePreviewViewModel: ObservableObject {

    // MARK: Observable view state

    /// Current render/availability status (R2.3, R2.4).
    @Published public private(set) var status: LivePreviewStatus

    /// Whether the camera reports audio available; gates the mute control (R2.6).
    @Published public private(set) var audioAvailable: Bool

    /// Whether live audio is currently muted (R2.6).
    @Published public private(set) var isAudioMuted: Bool

    // MARK: Dependencies

    private let preview: LivePreviewing
    private var cancellables: Set<AnyCancellable> = []

    public init(preview: LivePreviewing) {
        self.preview = preview
        self.status = preview.status
        self.audioAvailable = preview.audioAvailable
        self.isAudioMuted = preview.isAudioMuted
        bind()
    }

    private func bind() {
        guard let concrete = preview as? LivePreview else { return }
        concrete.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)
        concrete.$audioAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.audioAvailable = $0 }
            .store(in: &cancellables)
        concrete.$isAudioMuted
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.isAudioMuted = $0 }
            .store(in: &cancellables)
    }

    // MARK: Derived display (R2.3, R2.4)

    /// True while the stream is rendering; the view shows the video surface and
    /// the resolution + signal indicators (R2.3). Only possible while connected
    /// (R2.4, Property 3).
    public var isRendering: Bool {
        if case .rendering = status { return true }
        return false
    }

    /// The rendered stream resolution while rendering, else nil (R2.3).
    public var resolution: StreamResolution? {
        if case .rendering(let resolution, _) = status { return resolution }
        return nil
    }

    /// A human-readable resolution label (e.g. "1920×1080") while rendering (R2.3).
    public var resolutionLabel: String? {
        resolution.map { "\($0.width)×\($0.height)" }
    }

    /// The current signal-quality indicator while rendering, else nil (R2.3).
    public var signal: SignalQuality? {
        if case .rendering(_, let signal) = status { return signal }
        return nil
    }

    /// The stream-unavailable message when the preview is in the unavailable
    /// state; the view surfaces a retry control alongside it (R2.4, R2.7).
    public var unavailableMessage: String? {
        if case .unavailable(let message) = status { return message }
        return nil
    }

    /// Whether a retry affordance should be offered (unavailable state) (R2.7).
    public var canRetry: Bool { unavailableMessage != nil }

    // MARK: Intents

    /// Opens the live stream (R2.2).
    public func open() async { await preview.open() }

    /// Closes the live stream when leaving the screen (R2.5).
    public func close() async { await preview.close() }

    /// Toggles the mute state; the subsystem ignores it unless audio is
    /// available (R2.6).
    public func toggleMute() { preview.setAudioMuted(!isAudioMuted) }

    /// Sets the mute state explicitly (R2.6).
    public func setMuted(_ muted: Bool) { preview.setAudioMuted(muted) }

    /// Retries opening the stream after an unavailable state (R2.7).
    public func retry() async { await preview.retry() }
}

// MARK: - MediaBrowserViewModel (R3.1, R3.2, R3.5, R3.6, R3.8)

/// A single clip row prepared for display: the subsystem's `ClipRow` augmented
/// with the pre-formatted duration (H:M:S) and size (MB) strings produced by the
/// pure ClipLogic helpers (R3.3). The view renders these verbatim.
public struct ClipRowViewData: Identifiable, Equatable {
    /// Underlying browser row (metadata + downloaded flag + indicators).
    public let row: ClipRow

    public init(row: ClipRow) {
        self.row = row
    }

    /// Stable identity for SwiftUI lists.
    public var id: ClipID { row.id }

    /// Clip identifier.
    public var clipID: ClipID { row.metadata.id }

    /// Recording start timestamp (R3.3).
    public var startTimestamp: Date { row.metadata.startTimestamp }

    /// Duration formatted as hours:minutes:seconds via ClipLogic (R3.3).
    public var durationText: String { formatDuration(row.metadata.duration) }

    /// Size in megabytes via ClipLogic, formatted with two decimals (R3.3).
    public var sizeText: String {
        String(format: "%.2f MB", megabytes(fromBytes: row.metadata.sizeBytes))
    }

    /// Whether the clip already exists in the Local_Library.
    public var isDownloaded: Bool { row.isDownloaded }

    /// Type indicator — event marker iff the clip type is event (R3.4).
    public var typeMarker: ClipTypeIndicator { row.typeMarker }

    /// Protection indicator — protected marker iff Emergency_Footage (R6.1).
    public var protectionMarker: ClipProtectionIndicator { row.protectionMarker }
}

/// Presentation state for the media browser screen. Mirrors `MediaBrowsing`'s
/// rows, load state, and active filter, maps rows to display view data with
/// ClipLogic-formatted strings (R3.3), and forwards the load / setFilter / retry
/// intents (R3.1, R3.2, R3.5, R3.6, R3.8). Ordering and filtering are performed
/// by the subsystem's pure logic; the view model does not reorder or re-filter.
@MainActor
public final class MediaBrowserViewModel: ObservableObject {

    // MARK: Observable view state

    /// Display rows for the current filter, ordered descending (R3.5, R3.7),
    /// each carrying pre-formatted duration/size strings (R3.3).
    @Published public private(set) var rows: [ClipRowViewData] = []

    /// Current load state (R3.2, R3.6, R3.8).
    @Published public private(set) var loadState: BrowserLoadState

    /// Active clip-type filter (R3.5, R3.6).
    @Published public private(set) var filter: ClipFilter

    // MARK: Dependencies

    private let browser: MediaBrowsing
    private var cancellables: Set<AnyCancellable> = []

    public init(browser: MediaBrowsing) {
        self.browser = browser
        self.loadState = browser.loadState
        self.filter = browser.filter
        self.rows = browser.clips.map(ClipRowViewData.init)
        bind()
    }

    private func bind() {
        guard let concrete = browser as? MediaBrowser else { return }
        concrete.$clips
            .receive(on: RunLoop.main)
            .sink { [weak self] clips in
                self?.rows = clips.map(ClipRowViewData.init)
            }
            .store(in: &cancellables)
        concrete.$loadState
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.loadState = $0 }
            .store(in: &cancellables)
        concrete.$filter
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.filter = $0 }
            .store(in: &cancellables)
    }

    // MARK: Derived display (R3.2, R3.6, R3.8)

    /// Whether the loading indicator should be shown (R3.2).
    public var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    /// The empty-state message (empty library / no matching clips / no
    /// emergency footage), else nil (R3.6, R3.8, R6.3).
    public var emptyMessage: String? {
        if case .empty(let message) = loadState { return message }
        return nil
    }

    /// A failure/connection-lost message with a retry affordance, else nil
    /// (R3.9, R3.10).
    public var errorMessage: String? {
        switch loadState {
        case .failed(let message), .connectionLost(let message): return message
        case .loading, .loaded, .empty: return nil
        }
    }

    /// Whether a retry control should be offered (R3.9, R3.10).
    public var canRetry: Bool { errorMessage != nil }

    // MARK: Intents

    /// Loads the clip list from the camera (R3.1).
    public func load() async { await browser.load() }

    /// Sets the active filter; the subsystem re-applies it preserving order
    /// (R3.5, R3.6).
    public func setFilter(_ filter: ClipFilter) { browser.setFilter(filter) }

    /// Re-initiates retrieval after a failure (R3.9, R3.10).
    public func retry() async { await browser.retry() }
}
