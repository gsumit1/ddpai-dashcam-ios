// MockCameraProtocolAdapter — test-support / in-memory implementation
//
// Task 5.5: a programmable, dependency-free `CameraProtocolAdapter` for driving
// subsystem and integration tests deterministically, with no real camera and no
// network/AVFoundation. It lives in the MAIN library target (not Tests/) so it
// builds with `swift build` and is available to both subsystem code paths and
// the test targets layered on top.
//
// What it does:
//   • Request builders delegate to a real `DDPAICameraProtocolAdapter` by
//     default, so the HTTP requests look exactly like production (useful when a
//     test also drives `MockHTTPControlClient` keyed by request). The builders
//     are individually overridable for tests that need a specific request.
//   • Parsers (`parseSession`, `parseClipList`, `parseSetting`) are fully
//     programmable: a test configures the exact value to return, or an error to
//     throw, for each parse. This lets Connection_Manager, Media_Browser, and
//     Settings_Controller be exercised against canned responses without any
//     wire-format coupling (R1.2, R1.6).
//   • `supportedModels` is programmable to exercise the unsupported-model path
//     (R1.6).
//
// Thread-safety: all mutable programmable state is guarded by a lock so the mock
// is `Sendable` and safe to configure before, and read during, async subsystem
// calls.

import Foundation

/// A programmable, in-memory `CameraProtocolAdapter` for tests.
///
/// Configure canned parse results / errors and (optionally) overridden request
/// builders, then inject it wherever a subsystem expects a `CameraProtocolAdapter`.
public final class MockCameraProtocolAdapter: CameraProtocolAdapter, @unchecked Sendable {

    // MARK: Programmable parse outcomes

    /// A canned outcome for a parse call: either a value to return or an error
    /// to throw. Used for `parseSession`, `parseClipList`, and per-key
    /// `parseSetting` so a test picks exactly what the subsystem observes.
    public enum Outcome<Value> {
        case success(Value)
        case failure(Error)

        func resolve() throws -> Value {
            switch self {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    // MARK: Overridable request builders

    /// Optional overrides for each request builder. When `nil`, the builder
    /// delegates to the wrapped real adapter so requests match production.
    public struct RequestOverrides: Sendable {
        public var session: (@Sendable () -> HTTPRequest)?
        public var clipList: (@Sendable () -> HTTPRequest)?
        public var clipDownload: (@Sendable (ClipID, Int64) -> HTTPRequest)?
        public var clipPlaybackURL: (@Sendable (ClipID) -> URL)?
        public var liveStreamURL: (@Sendable () -> URL)?
        public var lock: (@Sendable (ClipID, Bool) -> HTTPRequest)?
        public var settingsRead: (@Sendable (SettingKey) -> HTTPRequest)?
        public var settingsWrite: (@Sendable (SettingKey, SettingValue) -> HTTPRequest)?

        public init() {}
    }

    // MARK: State

    private let lock = NSLock()
    private let base: DDPAICameraProtocolAdapter

    // Guarded-by-`lock` mutable programmable state.
    private var _supportedModels: Set<String>
    private var _overrides = RequestOverrides()
    private var _sessionOutcome: Outcome<CameraSession>?
    private var _clipListOutcome: Outcome<[ClipMetadata]>?
    private var _settingOutcomes: [SettingKey: Outcome<SettingValue>] = [:]
    private var _defaultSettingOutcome: Outcome<SettingValue>?

    // Call recording, so tests can assert what the subsystem asked for.
    private var _sessionRequestCount = 0
    private var _clipListRequestCount = 0
    private var _lockRequests: [(clipID: ClipID, locked: Bool)] = []
    private var _settingsWrites: [(key: SettingKey, value: SettingValue)] = []

    // MARK: Init

    /// Creates a mock backed by a real adapter for default request shapes.
    ///
    /// - Parameters:
    ///   - base: the real adapter used for non-overridden request builders.
    ///   - supportedModels: initial supported-model set (defaults to the base
    ///     adapter's set).
    public init(
        base: DDPAICameraProtocolAdapter = DDPAICameraProtocolAdapter(),
        supportedModels: Set<String>? = nil
    ) {
        self.base = base
        self._supportedModels = supportedModels ?? base.supportedModels
    }

    // MARK: - Configuration (programmable)

    /// Programs the result of the next `parseSession(_:)` call.
    @discardableResult
    public func stubSession(_ outcome: Outcome<CameraSession>) -> Self {
        withLock { _sessionOutcome = outcome }
        return self
    }

    /// Programs a successful session with the given model id and token.
    @discardableResult
    public func stubSession(modelID: String, token: String? = nil) -> Self {
        stubSession(.success(CameraSession(modelID: modelID, token: token)))
    }

    /// Programs the result of the next `parseClipList(_:)` call.
    @discardableResult
    public func stubClipList(_ outcome: Outcome<[ClipMetadata]>) -> Self {
        withLock { _clipListOutcome = outcome }
        return self
    }

    /// Programs a successful clip list.
    @discardableResult
    public func stubClipList(_ clips: [ClipMetadata]) -> Self {
        stubClipList(.success(clips))
    }

    /// Programs the result of `parseSetting(_:_:)` for a specific key.
    @discardableResult
    public func stubSetting(_ key: SettingKey, _ outcome: Outcome<SettingValue>) -> Self {
        withLock { _settingOutcomes[key] = outcome }
        return self
    }

    /// Programs a fallback `parseSetting(_:_:)` result for keys with no explicit stub.
    @discardableResult
    public func stubDefaultSetting(_ outcome: Outcome<SettingValue>) -> Self {
        withLock { _defaultSettingOutcome = outcome }
        return self
    }

    /// Replaces the set of supported models reported by `supportedModels` (R1.6).
    @discardableResult
    public func setSupportedModels(_ models: Set<String>) -> Self {
        withLock { _supportedModels = models }
        return self
    }

    /// Installs request-builder overrides.
    @discardableResult
    public func setRequestOverrides(_ overrides: RequestOverrides) -> Self {
        withLock { _overrides = overrides }
        return self
    }

    // MARK: - Recorded calls (assertions)

    public var sessionRequestCount: Int { withLock { _sessionRequestCount } }
    public var clipListRequestCount: Int { withLock { _clipListRequestCount } }
    public var lockRequests: [(clipID: ClipID, locked: Bool)] { withLock { _lockRequests } }
    public var settingsWrites: [(key: SettingKey, value: SettingValue)] { withLock { _settingsWrites } }

    // MARK: - CameraProtocolAdapter: request builders

    public func sessionRequest() -> HTTPRequest {
        let override: (@Sendable () -> HTTPRequest)? = withLock {
            _sessionRequestCount += 1
            return _overrides.session
        }
        return override?() ?? base.sessionRequest()
    }

    public func clipListRequest() -> HTTPRequest {
        let override: (@Sendable () -> HTTPRequest)? = withLock {
            _clipListRequestCount += 1
            return _overrides.clipList
        }
        return override?() ?? base.clipListRequest()
    }

    public func clipDownloadRequest(clipID: ClipID, fromByte: Int64) -> HTTPRequest {
        let override = withLock { _overrides.clipDownload }
        return override?(clipID, fromByte) ?? base.clipDownloadRequest(clipID: clipID, fromByte: fromByte)
    }

    public func clipPlaybackURL(clipID: ClipID) -> URL {
        let override = withLock { _overrides.clipPlaybackURL }
        return override?(clipID) ?? base.clipPlaybackURL(clipID: clipID)
    }

    public func liveStreamURL() -> URL {
        let override = withLock { _overrides.liveStreamURL }
        return override?() ?? base.liveStreamURL()
    }

    public func lockRequest(clipID: ClipID, locked: Bool) -> HTTPRequest {
        let override: (@Sendable (ClipID, Bool) -> HTTPRequest)? = withLock {
            _lockRequests.append((clipID, locked))
            return _overrides.lock
        }
        return override?(clipID, locked) ?? base.lockRequest(clipID: clipID, locked: locked)
    }

    public func settingsReadRequest(_ key: SettingKey) -> HTTPRequest {
        let override = withLock { _overrides.settingsRead }
        return override?(key) ?? base.settingsReadRequest(key)
    }

    public func settingsWriteRequest(_ key: SettingKey, value: SettingValue) -> HTTPRequest {
        let override: (@Sendable (SettingKey, SettingValue) -> HTTPRequest)? = withLock {
            _settingsWrites.append((key, value))
            return _overrides.settingsWrite
        }
        return override?(key, value) ?? base.settingsWriteRequest(key, value: value)
    }

    // MARK: - CameraProtocolAdapter: response parsers

    public func parseSession(_ response: HTTPResponse) throws -> CameraSession {
        let outcome = withLock { _sessionOutcome }
        guard let outcome else {
            throw MockAdapterError.notStubbed("parseSession")
        }
        return try outcome.resolve()
    }

    public func parseClipList(_ response: HTTPResponse) throws -> [ClipMetadata] {
        let outcome = withLock { _clipListOutcome }
        guard let outcome else {
            throw MockAdapterError.notStubbed("parseClipList")
        }
        return try outcome.resolve()
    }

    public func parseSetting(_ key: SettingKey, _ response: HTTPResponse) throws -> SettingValue {
        let outcome = withLock { _settingOutcomes[key] ?? _defaultSettingOutcome }
        guard let outcome else {
            throw MockAdapterError.notStubbed("parseSetting(\(key))")
        }
        return try outcome.resolve()
    }

    public var supportedModels: Set<String> {
        withLock { _supportedModels }
    }

    // MARK: - Private

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Errors raised by the test-support mocks when asked for an outcome that was
/// never programmed. Hitting one of these in a test means the stub setup is
/// incomplete — it is intentionally loud rather than returning a silent default.
public enum MockAdapterError: Error, Equatable {
    /// A parse/response was requested but no canned outcome was configured.
    case notStubbed(String)
}
