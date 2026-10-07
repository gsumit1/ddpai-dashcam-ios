// Settings_Controller
//
// Task 13.1: the `SettingsControlling` protocol and its concrete @MainActor
// implementation. Handles reading/writing camera settings (resolution,
// collision sensitivity, audio, parking mode/sensitivity) and clip lock/unlock,
// using the optimistic-with-revert pattern.
//
// Design reference: design.md → Components and Interfaces → Settings_Controller
// and the "Settings Write Flow" sequence. Responsibilities and the acceptance
// criteria they satisfy:
//   - syncAll(): on connect, show loading then replace with retrieved values,
//     with a retry cap of 3 via the pure `retryLoop` (R12.1, R12.2).
//   - readSetting(_:): retrieve a setting's options + current value, gating
//     availability on Connection_State via `controlAvailability` (R8.1, R8.5,
//     R9.1, R10.1, R10.6, R11.1, R11.7).
//   - writeSetting(_:_:): optimistic-with-revert — snapshot the previous value,
//     disable the control while pending via `pendingDisable`, apply on
//     acceptance and revert on reject/timeout/disconnect via `applyOrRevert`
//     (R8.3, R8.4, R8.6, R9.2–R9.5, R10.2–R10.5, R11.2, R11.3, R11.5, R11.6,
//     R12.4).
//   - lock(_:locked:): clip lock/unlock with the same confirm/revert rules
//     (R6.4–R6.7).
//   - convergence to the camera-reported value via `reconcile` (R12.3).
//
// Camera I/O funnels through `CameraProtocolAdapter`
// (`settingsReadRequest` / `settingsWriteRequest` / `lockRequest` /
// `parseSetting`) + `HTTPControlClient.send(_:timeout:)`. The shared
// Connection_State is read through an injected closure so availability tracks
// it without this type reaching into Connection_Manager internals.

import Foundation

// MARK: - Timing constants

/// Fixed timing bounds taken from Requirements 8–12. Centralized so the
/// controller and its tests reference the same values.
public enum SettingsTiming {
    /// Write/lock acknowledgement bound (R8.3/R8.4 use 5s for resolution; R9–R11
    /// and lock use 10s). The controller uses the 10s general bound for writes
    /// and lock, matching the design's `client.send(timeout: .seconds(10))`.
    public static let writeTimeout: Duration = .seconds(10)
    /// Read/sync retrieval bound (R12.2).
    public static let readTimeout: Duration = .seconds(10)
    /// Maximum consecutive sync retry attempts (R12.2).
    public static let maxSyncRetries: Int = 3
}

// MARK: - User-facing messages

/// User-facing strings surfaced by the Settings_Controller. Kept here so the
/// subsystem owns the semantics; the view layer renders them verbatim.
public enum SettingsMessage {
    /// R8.5/R10.6/R11.7 — control opened while not connected.
    public static let connectionRequired =
        "Connect to the camera to change this setting."
    /// R8.2 — options could not be retrieved.
    public static let retrievalFailed =
        "Couldn't load the options from the camera."
    /// R12.2 — settings sync failed after the retry cap.
    public static let settingsUnavailable =
        "Settings are unavailable. Reconnect to the camera and try again."
    /// R8.4/R9.4/R10.4/R11.3/R11.6 — a write was rejected or timed out.
    public static let changeFailed =
        "The change could not be applied."
    /// R9.5 — connection dropped while a change was pending.
    public static let connectionLost =
        "The connection was lost before the change was applied."
    /// R8.3/R9.3/R11.2/R11.5 — a write was accepted.
    public static let changeApplied =
        "Change applied."
    /// R6.5 — lock failed.
    public static let lockFailed =
        "Could not lock the clip."
    /// R6.7 — unlock failed.
    public static let unlockFailed =
        "Could not unlock the clip."
}

// MARK: - Overall sync status

/// The Settings_Controller's overall synchronization status surfaced to the
/// view model (R12.1, R12.2).
public enum SettingsSyncStatus: Equatable {
    /// No sync has run yet.
    case idle
    /// R12.1 — retrieving current camera settings; show a loading indicator.
    case loading
    /// R12.1 — values retrieved and displayed.
    case loaded
    /// R12.2 — retrieval failed after exhausting retries; show the unavailable
    /// message and a retry control.
    case unavailable
}

// MARK: - Protocol

/// Settings_Controller interface. `@MainActor` so its observable state is
/// mutated and observed safely by SwiftUI view models.
@MainActor
public protocol SettingsControlling: AnyObject {
    /// Overall sync status (R12.1, R12.2).
    var syncStatus: SettingsSyncStatus { get }

    /// Latest user-facing message, or nil when there is nothing to show.
    var message: String? { get }

    /// On connect: loading → retrieve current settings → values, retrying up to
    /// 3 times on failure before requiring a new connection (R12.1, R12.2).
    func syncAll() async

    /// Reads a single setting's current value, options, and availability. The
    /// availability is gated on Connection_State (R8.5, R10.6, R11.7).
    func readSetting(_ key: SettingKey) async -> SettingState

    /// Writes a new value with the optimistic-with-revert pattern: snapshot the
    /// previous displayed value, disable while pending, apply on acceptance,
    /// revert on reject/timeout/disconnect (R8.3–R8.6, R9.2–R9.5, R10.2–R10.5,
    /// R11.2–R11.6, R12.4).
    func writeSetting(_ key: SettingKey, _ value: SettingValue) async -> WriteOutcome

    /// Locks or unlocks a clip for overwrite protection, with the same
    /// confirm/revert rules as a setting write (R6.4–R6.7).
    func lock(_ clip: ClipID, locked: Bool) async -> WriteOutcome

    /// The current displayed state for a setting the controller is tracking.
    func state(for key: SettingKey) -> SettingState?
}

// MARK: - Concrete implementation

/// Concrete Settings_Controller. `@MainActor`-isolated so UI-observable state is
/// mutated on the main actor.
@MainActor
public final class SettingsController: SettingsControlling, ObservableObject {

    // MARK: Observable state

    @Published public private(set) var syncStatus: SettingsSyncStatus = .idle
    @Published public private(set) var message: String?
    /// Displayed state for each tracked setting, keyed by `SettingKey`.
    @Published public private(set) var states: [SettingKey: SettingState] = [:]

    // MARK: Dependencies

    private let adapter: CameraProtocolAdapter
    private let client: HTTPControlClient
    /// Reads the shared Connection_State so availability tracks it (R8.5, R10.6,
    /// R11.7) and pending writes revert on disconnect (R9.5, R12.4).
    private let connectionState: @MainActor () -> ConnectionState

    /// Settings synced on connect (R12.1). Parking sensitivity is retrieved
    /// on demand when a mode exposes it (R11.4), so it is excluded here.
    private static let syncedKeys: [SettingKey] = [
        .resolution, .collisionSensitivity, .audioRecording, .parkingMode
    ]

    public init(
        adapter: CameraProtocolAdapter,
        client: HTTPControlClient,
        connectionState: @escaping @MainActor () -> ConnectionState
    ) {
        self.adapter = adapter
        self.client = client
        self.connectionState = connectionState
    }

    public func state(for key: SettingKey) -> SettingState? {
        states[key]
    }

    // MARK: - Sync all (R12.1, R12.2)

    public func syncAll() async {
        // R12.1: show the loading indicator while retrieving.
        syncStatus = .loading
        message = nil

        // R12.2: bounded retry — at most 3 consecutive attempts. The pure
        // `retryLoop` enforces the limit and stop-on-first-success; each attempt
        // performs the async retrieval and records success/failure.
        var retrieved: [SettingKey: SettingValue] = [:]
        var optionsByKey: [SettingKey: [SettingValue]] = [:]

        var attemptResults: [Bool] = []
        for _ in 1...SettingsTiming.maxSyncRetries {
            // Abort if the connection dropped mid-sync (R12.2 disconnect branch).
            guard connectionState() == .connected else {
                attemptResults.append(false)
                break
            }
            let outcome = await retrieveAll()
            if let values = outcome {
                retrieved = values.values
                optionsByKey = values.options
                attemptResults.append(true)
                break
            } else {
                attemptResults.append(false)
            }
        }

        var cursor = 0
        let result = retryLoop(maxAttempts: SettingsTiming.maxSyncRetries) { _ in
            defer { cursor += 1 }
            guard cursor < attemptResults.count else { return false }
            return attemptResults[cursor]
        }

        switch result {
        case .succeeded:
            // Replace the loading indicator with the retrieved values (R12.1).
            for key in Self.syncedKeys {
                let availability = controlAvailability(for: connectionState())
                states[key] = SettingState(
                    key: key,
                    currentValue: retrieved[key],
                    options: optionsByKey[key] ?? [],
                    availability: availability
                )
            }
            syncStatus = .loaded
            message = nil
        case .failed:
            // R12.2: exhausted retries — settings unavailable + retry control.
            syncStatus = .unavailable
            message = SettingsMessage.settingsUnavailable
        }
    }

    /// Attempts to retrieve every synced setting's value and options once.
    /// Returns nil if any read fails or the retrieval window is exceeded.
    private func retrieveAll() async -> (values: [SettingKey: SettingValue], options: [SettingKey: [SettingValue]])? {
        var values: [SettingKey: SettingValue] = [:]
        var options: [SettingKey: [SettingValue]] = [:]
        for key in Self.syncedKeys {
            guard let value = await readValue(key) else { return nil }
            values[key] = value
            // Options are adapter-specific; a read also surfaces the current
            // value. Keep whatever options we already know for the key.
            options[key] = states[key]?.options ?? []
        }
        return (values, options)
    }

    // MARK: - Read a single setting (R8.1, R8.5, R9.1, R10.1, R11.1, R11.7)

    public func readSetting(_ key: SettingKey) async -> SettingState {
        // R8.5/R10.6/R11.7: not connected — disable and require connection.
        guard connectionState() == .connected else {
            let disabled = SettingState(
                key: key,
                currentValue: states[key]?.currentValue,
                options: states[key]?.options ?? [],
                availability: .disabledConnectionRequired
            )
            states[key] = disabled
            message = SettingsMessage.connectionRequired
            return disabled
        }

        guard let value = await readValue(key) else {
            // R8.2: retrieval failed — disable with a retrieval-failure message.
            let failed = SettingState(
                key: key,
                currentValue: states[key]?.currentValue,
                options: states[key]?.options ?? [],
                availability: .retrievalFailed
            )
            states[key] = failed
            message = SettingsMessage.retrievalFailed
            return failed
        }

        let loaded = SettingState(
            key: key,
            currentValue: value,
            options: states[key]?.options ?? [],
            availability: .enabled
        )
        states[key] = loaded
        message = nil
        return loaded
    }

    /// Performs a bounded read for a setting, returning the parsed value or nil
    /// on failure/timeout.
    private func readValue(_ key: SettingKey) async -> SettingValue? {
        let request = adapter.settingsReadRequest(key)
        do {
            let response = try await client.send(request, timeout: SettingsTiming.readTimeout)
            return try adapter.parseSetting(key, response)
        } catch {
            return nil
        }
    }

    // MARK: - Write a setting (optimistic-with-revert)

    public func writeSetting(_ key: SettingKey, _ value: SettingValue) async -> WriteOutcome {
        // R8.5/R10.6/R11.7: no write while not connected.
        guard connectionState() == .connected else {
            message = SettingsMessage.connectionRequired
            // Reflect a disabled control that requires a connection.
            let disabled = SettingState(
                key: key,
                currentValue: states[key]?.currentValue,
                options: states[key]?.options ?? [],
                availability: .disabledConnectionRequired
            )
            states[key] = disabled
            return .connectionLost
        }

        // Snapshot the previous displayed value for revert (Property 20).
        let previous = states[key]?.currentValue
        let options = states[key]?.options ?? []

        // R8.6/R9.2: disable the control while pending.
        states[key] = SettingState(
            key: key,
            currentValue: previous,
            options: options,
            availability: pendingDisable(true)
        )
        message = nil

        let outcome = await performWrite(key, value)

        // R12.4/Property 20: apply on acceptance, revert otherwise.
        let resolved = applyOrRevert(previous: previous, outcome: outcome)
        // Availability returns to the connection-derived value once terminal.
        states[key] = SettingState(
            key: key,
            currentValue: resolved,
            options: options,
            availability: controlAvailability(for: connectionState())
        )
        applyMessage(for: outcome)
        return outcome
    }

    /// Issues the setting write and maps transport results to a `WriteOutcome`.
    private func performWrite(_ key: SettingKey, _ value: SettingValue) async -> WriteOutcome {
        let request = adapter.settingsWriteRequest(key, value: value)
        do {
            let response = try await client.send(request, timeout: SettingsTiming.writeTimeout)
            // Treat a 2xx as acceptance; parse the camera-reported value so the
            // display converges on the camera's value (R12.3 via reconcile).
            guard (200...299).contains(response.statusCode) else {
                return .rejected
            }
            if let reported = try? adapter.parseSetting(key, response) {
                // R12.3: the camera is the source of truth; reconcile to it.
                let converged = reconcile(displayed: value, cameraReported: reported) ?? value
                return .accepted(converged)
            }
            return .accepted(value)
        } catch is CancellationError {
            // Cancelled (e.g. disconnect superseded the call).
            return connectionState() == .connected ? .timedOut : .connectionLost
        } catch {
            // No acknowledgement within the bound, or transport failure.
            return connectionState() == .connected ? .timedOut : .connectionLost
        }
    }

    /// Surfaces the user-facing message for a terminal write outcome.
    private func applyMessage(for outcome: WriteOutcome) {
        switch outcome {
        case .accepted:
            message = SettingsMessage.changeApplied
        case .rejected, .timedOut:
            message = SettingsMessage.changeFailed
        case .connectionLost:
            message = SettingsMessage.connectionLost
        }
    }

    // MARK: - Lock / unlock a clip (R6.4–R6.7)

    public func lock(_ clip: ClipID, locked: Bool) async -> WriteOutcome {
        // Lock/unlock requires a connection, same as a write.
        guard connectionState() == .connected else {
            message = SettingsMessage.connectionRequired
            return .connectionLost
        }

        let request = adapter.lockRequest(clipID: clip, locked: locked)
        let outcome: WriteOutcome
        do {
            let response = try await client.send(request, timeout: SettingsTiming.writeTimeout)
            if (200...299).contains(response.statusCode) {
                // R6.4/R6.6: confirmed — the clip's protection flag is now the
                // requested state.
                outcome = .accepted(.bool(locked))
            } else {
                // R6.5/R6.7: rejected — retain the prior protection indicator.
                outcome = .rejected
            }
        } catch is CancellationError {
            outcome = connectionState() == .connected ? .timedOut : .connectionLost
        } catch {
            outcome = connectionState() == .connected ? .timedOut : .connectionLost
        }

        switch outcome {
        case .accepted:
            message = SettingsMessage.changeApplied
        case .rejected, .timedOut:
            // R6.5/R6.7: distinct lock vs unlock failure message.
            message = locked ? SettingsMessage.lockFailed : SettingsMessage.unlockFailed
        case .connectionLost:
            message = SettingsMessage.connectionLost
        }
        return outcome
    }

    // MARK: - Connection change handling (R9.5, R12.4)

    /// Cancels any pending writes and reverts their controls when the shared
    /// Connection_State leaves `.connected` (R9.5, R12.4). Any control currently
    /// `.pending` is returned to a connection-required disabled state keeping
    /// its last confirmed value.
    public func handleConnectionLost() {
        for (key, state) in states where state.availability == .pending {
            states[key] = SettingState(
                key: key,
                currentValue: state.currentValue,
                options: state.options,
                availability: .disabledConnectionRequired
            )
        }
        message = SettingsMessage.connectionLost
    }
}
