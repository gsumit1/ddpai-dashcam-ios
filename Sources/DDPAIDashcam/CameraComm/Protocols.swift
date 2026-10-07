// Camera Communication Layer — protocols and wire types
//
// Task 5.1: protocol-neutral abstractions for all camera I/O. These are
// definitions only; concrete adapters/clients land in tasks 5.2–5.5.
//
// Design reference: design.md → Components and Interfaces → Camera
// Communication Layer. The only place that knows DDPAI-specific wire details
// is the `CameraProtocolAdapter` implementation; everything else depends on
// these neutral types so the camera protocol can change per model without
// touching application logic (R1.2, R1.3, R1.6).

import Foundation

// MARK: - Wire Types

/// An HTTP method on the camera's control channel.
public enum HTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// A protocol-neutral HTTP request built by `CameraProtocolAdapter`.
///
/// The adapter encodes all DDPAI-specific endpoint paths, parameter names, and
/// headers into this value; the `HTTPControlClient` executes it without needing
/// to understand the camera's protocol. Ranged downloads are expressed via the
/// `Range` header (e.g. `bytes=<fromByte>-`) set by the adapter.
public struct HTTPRequest: Equatable, Sendable {
    /// Absolute URL of the camera endpoint (on the hotspot gateway).
    public let url: URL
    /// HTTP method for the request.
    public let method: HTTPMethod
    /// Request headers (e.g. `Range` for ranged GET).
    public let headers: [String: String]
    /// Optional request body.
    public let body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A protocol-neutral HTTP response returned by `HTTPControlClient` and parsed
/// by `CameraProtocolAdapter`.
public struct HTTPResponse: Equatable, Sendable {
    /// HTTP status code.
    public let statusCode: Int
    /// Response headers.
    public let headers: [String: String]
    /// Response body payload.
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// The result of a successful session establishment with the camera.
///
/// Carries the camera-reported model identifier used to validate against the
/// adapter's `supportedModels` (R1.6) and to display the connected model (R1.3).
public struct CameraSession: Equatable, Sendable {
    /// Camera-reported model identifier, matched against `supportedModels`.
    public let modelID: String
    /// Opaque session token/identifier issued by the camera, if any, used to
    /// authorize subsequent control-channel requests.
    public let token: String?

    public init(modelID: String, token: String? = nil) {
        self.modelID = modelID
        self.token = token
    }
}

/// A progress update emitted while a clip is downloading over the control
/// channel's ranged GET endpoint (R5.2).
public struct DownloadProgress: Equatable, Sendable {
    /// Total bytes transferred so far, including any resumed-from offset.
    public let completedBytes: Int64
    /// Total expected size of the clip in bytes, when known.
    public let totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

/// An opaque handle to an active live-stream session, returned by
/// `LiveStreamClient.start` and passed back to `stop` to tear it down.
public struct LiveStreamHandle: Equatable, Sendable {
    /// Opaque session identifier for the RTSP/RTP media session.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// A single decoded video frame delivered by the live-stream client.
///
/// Pixel data is carried as an opaque buffer so this type stays free of any
/// AVFoundation/CoreVideo dependency; the view layer renders it. Dimensions
/// drive the resolution indicator surfaced while rendering (R2.3).
public struct DecodedFrame: Equatable, Sendable {
    /// Decoded frame payload (platform decoder output).
    public let pixelData: Data
    /// Frame width in pixels.
    public let width: Int
    /// Frame height in pixels.
    public let height: Int
    /// Presentation timestamp of the frame.
    public let presentationTime: Duration

    public init(
        pixelData: Data,
        width: Int,
        height: Int,
        presentationTime: Duration
    ) {
        self.pixelData = pixelData
        self.width = width
        self.height = height
        self.presentationTime = presentationTime
    }
}

// MARK: - Protocols

/// Encapsulates all DDPAI-specific wire details. The only type that knows
/// endpoint paths, parameter names, and stream URL formats (R1.3).
public protocol CameraProtocolAdapter {
    /// Builds the request that establishes a session with the camera.
    func sessionRequest() -> HTTPRequest
    /// Parses a session response, including the camera model id (R1.6).
    func parseSession(_ response: HTTPResponse) throws -> CameraSession
    /// Builds the request that enumerates recorded clips.
    func clipListRequest() -> HTTPRequest
    /// Parses the clip-list response into clip metadata.
    func parseClipList(_ response: HTTPResponse) throws -> [ClipMetadata]
    /// Builds a ranged GET request to download a clip from the given byte
    /// offset (used for resumable downloads).
    func clipDownloadRequest(clipID: ClipID, fromByte: Int64) -> HTTPRequest
    /// The URL used to stream a recorded clip for playback.
    func clipPlaybackURL(clipID: ClipID) -> URL
    /// The RTSP URL used to open the live preview stream.
    func liveStreamURL() -> URL
    /// Builds the request that locks or unlocks a clip.
    func lockRequest(clipID: ClipID, locked: Bool) -> HTTPRequest
    /// Builds the request that reads the current value of a setting.
    func settingsReadRequest(_ key: SettingKey) -> HTTPRequest
    /// Builds the request that writes a new value for a setting.
    func settingsWriteRequest(_ key: SettingKey, value: SettingValue) -> HTTPRequest
    /// Parses a settings response into a typed value for the given key.
    func parseSetting(_ key: SettingKey, _ response: HTTPResponse) throws -> SettingValue
    /// The set of camera model identifiers this adapter supports (R1.6).
    var supportedModels: Set<String> { get }
}

/// The camera control / data channel: executes protocol-neutral HTTP requests
/// built by a `CameraProtocolAdapter`.
public protocol HTTPControlClient {
    /// Sends a request with a caller-supplied timeout bound and returns the
    /// response. Timeout/cancellation map to Swift Concurrency task
    /// cancellation (R1.2, R1.5).
    func send(_ request: HTTPRequest, timeout: Duration) async throws -> HTTPResponse
    /// Performs a ranged, resumable download to `fileURL`, resuming from the
    /// given byte offset, producing progress updates (R5.2, R5.6).
    func download(
        _ request: HTTPRequest,
        to fileURL: URL,
        resumingFrom byte: Int64
    ) -> AsyncThrowingStream<DownloadProgress, Error>
}

/// The media channel for Live_Preview: an RTSP-style control session carrying
/// decoded H.264 frames and optional audio.
public protocol LiveStreamClient {
    /// Opens the stream (DESCRIBE/SETUP/PLAY) and returns a handle.
    func start(url: URL) async throws -> LiveStreamHandle
    /// Tears down the stream (TEARDOWN) for the given handle.
    func stop(_ handle: LiveStreamHandle) async
    /// The stream of decoded video frames while rendering.
    var frames: AsyncStream<DecodedFrame> { get }
    /// Whether the current stream carries an audio track (R2.6).
    var audioAvailable: Bool { get }
    /// Mutes or unmutes the stream's audio.
    func setAudioMuted(_ muted: Bool)
}
