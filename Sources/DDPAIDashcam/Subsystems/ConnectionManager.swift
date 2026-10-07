// Connection_Manager
//
// Task 7.1: `ConnectionManaging` protocol and the concrete `ConnectionManager`
// that owns the single observable `Connection_State` every other subsystem
// observes.
//
// Design reference: design.md → Components and Interfaces → Connection_Manager,
// plus the "Connection State as Shared Observable" and "Reconnection Flow"
// sections. This type is the single source of truth for the link status
// (R1.1). It requires the device to be joined to the camera Wi-Fi_Hotspot
// before connecting (R1.4), enforces a 10s connect timeout (R1.2, R1.5),
// validates the camera model against the adapter's `supportedModels` (R1.6),
// detects link loss within 5s while connected (R1.7), runs up to 3 automatic
// reconnect attempts at 10s each (R1.8), and falls back to disconnected when
// those attempts are exhausted (R1.9).
//
// Camera I/O funnels through the protocol-neutral `CameraProtocolAdapter` +
// `HTTPControlClient` (session establishment via `adapter.sessionRequest()` /
// `client.send(_:timeout:)` / `adapter.parseSession`). Hotspot-join and
// link-loss detection funnel through an injectable `CameraReachability` so the
// manager is testable without the Network framework; the default is backed by
// `NWPathMonitor`.

import Combine
import Foundation

#if canImport(Network)
import Network
#endif

// MARK: - Timing constants

/// Fixed timing bounds taken from Requirement 1. Centralized so the manager and
/// its tests reference the same values.
public enum ConnectionTiming {
    /// Maximum time to establish a session on a connect attempt (R1.2, R1.5)
    /// and on each auto-reconnect attempt (R1.8).
    public static let connectTimeout: Duration = .seconds(10)
    /// Maximum time to detect loss of the camera link while connected (R1.7).
    public static let linkLossDetection: Duration = .seconds(5)
    /// Maximum number of automatic reconnection attempts (R1.8).
    public static let maxReconnectAttempts: Int = 3
}

// MARK: - Reachability abstraction

/// Observes whether the iOS device is joined to the camera Wi-Fi_Hotspot.
///
/// Injected into `ConnectionManager` so hotspot-join detection (R1.4) and
/// link-loss detection (R1.7) can be driven deterministically in tests. The
/// production default, `NWPathReachability`, is backed by `NWPathMonitor`.
public protocol CameraReachability: Sendable {
    /// Whether the device currently has a usable link to the camera network.
    ///
    /// Checked synchronously before a connect attempt to satisfy R1.4 (remain
    /// disconnected and show the join instruction when not on the hotspot).
    func isOnHotspot() async -> Bool

    /// A stream of reachability updates (`true` = on-hotspot/usable link,
    /// `false` = link lost). The manager observes this while connected so it
    /// can transition to interrupted within the link-loss detection bound
    /// (R1.7). The stream should emit promptly on the underlying path change.
    func updates() -> AsyncStream<Bool>
}

// MARK: - Protocol

/// The Connection_Manager interface. Owns the observable `Connection_State`
/// (the single source of truth other subsystems observe) and the connected
/// camera model identifier.
@MainActor
public protocol ConnectionManaging: AnyObject {
    /// The current link status (R1.1). Published so view models and other
    /// subsystems react uniformly to connect/interrupt/disconnect transitions.
    var state: ConnectionState { get }

    /// Publisher for `state`, for observers that subscribe via Combine.
    var statePublisher: Published<ConnectionState>.Publisher { get }

    /// The camera-reported model identifier, available once connected (R1.3).
    /// `nil` whenever not connected.
    var cameraModel: String? { get }

    /// A user-facing status/instruction message describing the latest outcome
    /// (join instruction for R1.4, failure messages for R1.5/R1.6/R1.9,
    /// reconnection prompt for R1.8), or `nil` when there is nothing to show.
    var statusMessage: String? { get }

    /// Attempts to establish a session with the camera, honoring the 10s
    /// timeout and model check (R1.2–R1.6).
    func connect() async

    /// Tears down the session and returns to disconnected.
    func disconnect() async
}

// MARK: - User-facing messages

/// User-facing strings surfaced via `statusMessage`. Kept here (not scattered
/// in UI) so the manager fully owns the connection-state semantics; the view
/// layer renders them verbatim.
public enum ConnectionMessage {
    /// R1.4 — initiate connect while not joined to the camera hotspot.
    public static let joinHotspot =
        "Join the camera's Wi-Fi network, then try connecting again."
    /// R1.5 — session not established within the connect timeout.
    public static let connectTimedOut =
        "Could not establish a session with the camera. Please try again."
    /// R1.6 — camera reported an unsupported model identifier.
    public static func unsupportedModel(_ model: String) -> String {
        "The connected camera (\(model)) is not supported."
    }
    /// R1.8 — shown while automatic reconnection is in progress.
    public static let reconnecting =
        "The camera link was interrupted. Reconnecting…"
    /// R1.9 — all automatic reconnection attempts failed.
    public static let linkLost =
        "The camera link was lost. Please reconnect."
    /// Generic connect failure (non-timeout error during session setup).
    public static let connectFailed =
        "Could not connect to the camera. Please try again."
}

// MARK: - Errors

/// Internal errors used to drive connect/reconnect control flow.
enum ConnectionError: Error, Equatable {
    /// The connect attempt exceeded the 10s bound (R1.5).
    case timedOut
    /// The camera reported a model that is not in `supportedModels` (R1.6).
    case unsupportedModel(String)
}

// MARK: - Concrete manager

/// Concrete Connection_Manager. `@MainActor` so its published state is mutated
/// on the main actor and observed safely by SwiftUI view models.
@MainActor
public final class ConnectionManager: ConnectionManaging, ObservableObject {

    // MARK: Observable state

    /// Single source of truth for the link status (R1.1).
    @Published public private(set) var state: ConnectionState = .disconnected

    /// Camera model id, present only while connected (R1.3).
    @Published public private(set) var cameraModel: String?

    /// Latest user-facing instruction/failure message (R1.4–R1.9).
    @Published public private(set) var statusMessage: String?

    public var statePublisher: Published<ConnectionState>.Publisher { $state }

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let client: HTTPControlClient
    private let reachability: CameraReachability

    // MARK: Internal bookkeeping

    /// Task observing reachability updates while connected; cancelled on
    /// disconnect or when a link loss is handled.
    private var linkMonitorTask: Task<Void, Never>?

    public init(
        adapter: CameraProtocolAdapter,
        client: HTTPControlClient,
        reachability: CameraReachability
    ) {
        self.adapter = adapter
        self.client = client
        self.reachability = reachability
    }

    deinit {
        linkMonitorTask?.cancel()
    }

    // MARK: - Connect (R1.2–R1.6)

    public func connect() async {
        // Don't start a second connect while one is already in flight or active.
        guard state == .disconnected || state == .interrupted else { return }

        // R1.4: require hotspot join. Remain disconnected and show the join
        // instruction when the device is not on the camera network.
        guard await reachability.isOnHotspot() else {
            stopLinkMonitor()
            cameraModel = nil
            state = .disconnected
            statusMessage = ConnectionMessage.joinHotspot
            return
        }

        // R1.2: enter connecting and attempt to establish a session.
        state = .connecting
        statusMessage = nil

        do {
            let session = try await establishSession()
            // R1.3: connected; expose the model identifier.
            cameraModel = session.modelID
            state = .connected
            statusMessage = nil
            startLinkMonitor()
        } catch ConnectionError.unsupportedModel(let model) {
            // R1.6: unsupported model → disconnected with an unsupported message.
            failConnect(message: ConnectionMessage.unsupportedModel(model))
        } catch ConnectionError.timedOut {
            // R1.5: timeout → disconnected with a connection-failure message.
            failConnect(message: ConnectionMessage.connectTimedOut)
        } catch {
            // Any other failure during session setup → disconnected.
            failConnect(message: ConnectionMessage.connectFailed)
        }
    }

    public func disconnect() async {
        stopLinkMonitor()
        cameraModel = nil
        state = .disconnected
        statusMessage = nil
    }

    // MARK: - Session establishment with bounded timeout

    /// Establishes a session within the 10s connect bound (R1.2, R1.5) and
    /// validates the camera model against `supportedModels` (R1.6).
    ///
    /// The timeout is enforced via the `HTTPControlClient.send(_:timeout:)`
    /// bound; `.timedOut` is thrown if the call reports cancellation/timeout.
    private func establishSession(
        timeout: Duration = ConnectionTiming.connectTimeout
    ) async throws -> CameraSession {
        let request = adapter.sessionRequest()
        let response: HTTPResponse
        do {
            response = try await client.send(request, timeout: timeout)
        } catch is CancellationError {
            throw ConnectionError.timedOut
        } catch {
            // The client surfaces timeouts as its own error; treat any transport
            // failure as a connect timeout/failure for the connect path.
            throw ConnectionError.timedOut
        }

        let session = try adapter.parseSession(response)

        // R1.6: validate the reported model against the adapter's supported set.
        guard isModelSupported(session.modelID, in: adapter.supportedModels) else {
            throw ConnectionError.unsupportedModel(session.modelID)
        }
        return session
    }

    /// Shared handling for a failed connect attempt: clear the model, drop to
    /// disconnected, and surface the given message.
    private func failConnect(message: String) {
        stopLinkMonitor()
        cameraModel = nil
        state = .disconnected
        statusMessage = message
    }

    // MARK: - Link monitoring (R1.7)

    /// Begins observing reachability updates. On the first `false` emission
    /// (link lost) the manager transitions to interrupted and kicks off the
    /// auto-reconnect sequence (R1.7, R1.8). The 5s detection bound (R1.7) is
    /// delivered by the reachability source emitting promptly on path loss.
    private func startLinkMonitor() {
        stopLinkMonitor()
        linkMonitorTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.reachability.updates()
            for await isReachable in stream {
                if Task.isCancelled { return }
                if !isReachable {
                    await self.handleLinkLoss()
                    return
                }
            }
        }
    }

    private func stopLinkMonitor() {
        linkMonitorTask?.cancel()
        linkMonitorTask = nil
    }

    /// Handles detected link loss while connected: move to interrupted, show
    /// the reconnection prompt, and run the bounded auto-reconnect sequence.
    private func handleLinkLoss() async {
        // Only act if we were connected; ignore stale events.
        guard state == .connected else { return }
        state = .interrupted
        statusMessage = ConnectionMessage.reconnecting
        await autoReconnect()
    }

    // MARK: - Auto-reconnect (R1.8, R1.9)

    /// Runs up to 3 automatic reconnection attempts, each bounded at 10s, using
    /// the pure bounded-retry decision (`retryLoop`). On the first successful
    /// attempt the state returns to connected (R1.8); if all attempts fail the
    /// state falls back to disconnected with a link-lost message (R1.9).
    private func autoReconnect() async {
        // `retryLoop` is a pure synchronous decision function, so we evaluate
        // each attempt's async outcome into a captured result it can read. We
        // perform the actual async session establishment here and feed the
        // boolean outcome into the bounded loop so the limit/stop-on-success
        // semantics come from the shared Property-2 logic.
        var lastSession: CameraSession?
        var attempts: [Bool] = []

        // Pre-compute attempt outcomes up to the first success, bounded by the
        // max attempt count, so the pure retryLoop can enforce the bound.
        for attemptNumber in 1...ConnectionTiming.maxReconnectAttempts {
            // Abort the sequence if a disconnect/connect superseded us.
            guard state == .interrupted else { return }

            // Each attempt requires the hotspot to still be reachable.
            let reachable = await reachability.isOnHotspot()
            var succeeded = false
            if reachable {
                do {
                    let session = try await establishSession()
                    lastSession = session
                    succeeded = true
                } catch {
                    succeeded = false
                }
            }
            attempts.append(succeeded)
            if succeeded { break }
            _ = attemptNumber
        }

        var cursor = 0
        let outcome = retryLoop(maxAttempts: ConnectionTiming.maxReconnectAttempts) { _ in
            defer { cursor += 1 }
            guard cursor < attempts.count else { return false }
            return attempts[cursor]
        }

        switch outcome {
        case .succeeded:
            guard let session = lastSession else {
                // Defensive: treat a missing session as exhaustion.
                exhaustReconnect()
                return
            }
            cameraModel = session.modelID
            state = .connected
            statusMessage = nil
            startLinkMonitor()
        case .failed:
            // R1.9: all reconnect attempts failed → disconnected + link-lost.
            exhaustReconnect()
        }
    }

    /// Falls back to disconnected after reconnection exhaustion (R1.9).
    private func exhaustReconnect() {
        stopLinkMonitor()
        cameraModel = nil
        state = .disconnected
        statusMessage = ConnectionMessage.linkLost
    }
}

// MARK: - NWPathMonitor-backed reachability (production default)

#if canImport(Network)
/// Default `CameraReachability` backed by `NWPathMonitor` (Network framework).
///
/// Reports a usable Wi-Fi link as "on hotspot" and emits an update whenever the
/// path status changes, so the Connection_Manager can detect link loss within
/// the 5s bound (R1.7) and gate connect on hotspot join (R1.4).
public final class NWPathReachability: CameraReachability, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var currentPath: NWPath?

    /// - Parameter requiredInterfaceType: when provided, only paths using this
    ///   interface (e.g. `.wifi`, since the camera hotspot is Wi-Fi) count as
    ///   reachable. Defaults to `.wifi`.
    public init(requiredInterfaceType: NWInterface.InterfaceType? = .wifi) {
        if let type = requiredInterfaceType {
            self.monitor = NWPathMonitor(requiredInterfaceType: type)
        } else {
            self.monitor = NWPathMonitor()
        }
        self.queue = DispatchQueue(label: "com.ddpai.reachability")
        monitor.pathUpdateHandler = { [weak self] path in
            self?.setCurrentPath(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func setCurrentPath(_ path: NWPath) {
        lock.lock()
        currentPath = path
        lock.unlock()
    }

    private func latestPath() -> NWPath? {
        lock.lock()
        defer { lock.unlock() }
        return currentPath
    }

    public func isOnHotspot() async -> Bool {
        // If no path update has arrived yet, fall back to the monitor's current
        // path; treat `.satisfied` as reachable.
        let path = latestPath() ?? monitor.currentPath
        return path.status == .satisfied
    }

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            // Emit the current status immediately so observers have a baseline.
            let initial = (latestPath() ?? monitor.currentPath).status == .satisfied
            continuation.yield(initial)

            // Chain onto the monitor's update handler. The Connection_Manager
            // starts/stops observation around the connected window, so a single
            // active consumer is expected at a time.
            let previous = monitor.pathUpdateHandler
            monitor.pathUpdateHandler = { [weak self] path in
                self?.setCurrentPath(path)
                previous?(path)
                continuation.yield(path.status == .satisfied)
            }

            continuation.onTermination = { [weak self] _ in
                self?.monitor.pathUpdateHandler = previous
            }
        }
    }
}
#endif
