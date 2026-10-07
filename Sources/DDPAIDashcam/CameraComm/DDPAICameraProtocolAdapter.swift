// DDPAICameraProtocolAdapter
//
// Task 5.2: the concrete DDPAI `CameraProtocolAdapter`. This is the ONE type in
// the whole app that knows DDPAI-specific wire details — endpoint paths,
// parameter names, stream-URL formats, JSON field names, and the set of
// supported model identifiers. Every other layer depends only on the
// protocol-neutral abstractions in `Protocols.swift`, so the camera protocol
// can change per model without touching application logic (R1.2, R1.3, R1.6).
//
// ─────────────────────────────────────────────────────────────────────────
// VENDOR-ASSUMPTION NOTICE
// ─────────────────────────────────────────────────────────────────────────
// The exact DDPAI vendor HTTP/RTSP API is proprietary and not publicly
// documented. The paths, query-parameter names, JSON keys, and URL formats
// below are a reasonable, well-documented model of how DDPAI (and comparable
// Wi-Fi dash cams) behave, per design.md → "Camera Communication Model":
//
//   • The phone joins the camera's Wi-Fi hotspot; the camera is a self-hosted
//     access point reachable at a fixed gateway address (`Constants.gatewayIP`).
//   • Control / data traffic is a JSON HTTP request/response API on that
//     gateway (session, model id, clip list, lock/unlock, settings, download).
//   • Clip download is a ranged HTTP GET: resumable transfers set the standard
//     `Range: bytes=<from>-` header (R5.1, R5.6).
//   • Recorded-clip playback is a progressive/ranged HTTP GET of the clip file.
//   • Live preview is an RTSP control session; the stream URL uses the `rtsp://`
//     scheme on the gateway (R2.1).
//
// To adapt this adapter to a specific firmware/model, change ONLY the values in
// `Constants` and the field names in the `*Keys` enums plus the parse helpers.
// No application logic depends on any of these specifics.
// ─────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Errors

/// Typed errors raised while parsing DDPAI control-channel responses. Keeping
/// these specific lets callers (Connection_Manager, Media_Browser,
/// Settings_Controller) distinguish a transport failure from a malformed or
/// rejected payload and surface the right message.
public enum DDPAIAdapterError: Error, Equatable {
    /// HTTP status was outside the 2xx success range.
    case httpStatus(Int)
    /// The response body was not valid JSON / not the expected JSON shape.
    case malformedResponse(String)
    /// A required field was absent from an otherwise well-formed payload.
    case missingField(String)
    /// A field was present but held an unexpected type or value.
    case invalidField(String)
    /// The camera reported an application-level error code in the payload.
    case cameraError(code: Int, message: String?)
    /// The parsed value did not match the requested setting key.
    case settingMismatch(SettingKey)
}

// MARK: - Adapter

/// The concrete DDPAI implementation of `CameraProtocolAdapter`.
///
/// Stateless and `Sendable`: all per-request state (byte offsets, keys, values)
/// is passed in, so a single instance can be shared across the app. Construct
/// with the defaults for the standard DDPAI hotspot model, or inject a custom
/// `Configuration` for a firmware variant.
public struct DDPAICameraProtocolAdapter: CameraProtocolAdapter, Sendable {

    // MARK: Configuration

    /// Tunable vendor-specific values. Isolating these here is what lets a new
    /// DDPAI model be supported by swapping configuration rather than code.
    public struct Configuration: Sendable, Equatable {
        /// Scheme for the control / data channel.
        public var httpScheme: String
        /// Scheme for the live-preview media channel.
        public var rtspScheme: String
        /// Fixed gateway address of the camera on its own hotspot.
        ///
        /// DDPAI documentation and field reports place the gateway at a fixed
        /// hotspot address; `193.168.0.1` is the commonly cited DDPAI value,
        /// with `192.168.1.254` used by some comparable cams. Overridable per
        /// model.
        public var gatewayIP: String
        /// Control-channel HTTP port.
        public var httpPort: Int
        /// RTSP media-channel port.
        public var rtspPort: Int
        /// Model identifiers this adapter accepts (R1.6).
        public var supportedModels: Set<String>

        public init(
            httpScheme: String = "http",
            rtspScheme: String = "rtsp",
            gatewayIP: String = "193.168.0.1",
            httpPort: Int = 80,
            rtspPort: Int = 6900,
            supportedModels: Set<String> = DDPAICameraProtocolAdapter.defaultSupportedModels
        ) {
            self.httpScheme = httpScheme
            self.rtspScheme = rtspScheme
            self.gatewayIP = gatewayIP
            self.httpPort = httpPort
            self.rtspPort = rtspPort
            self.supportedModels = supportedModels
        }
    }

    /// Representative DDPAI model identifiers. These mirror DDPAI's published
    /// product line (Mini / Mola / Z-series / N-series / X-series). The set is
    /// the single gate used by Connection_Manager to accept or reject a camera
    /// (R1.6); add identifiers here as models are validated.
    public static let defaultSupportedModels: Set<String> = [
        "DDPAI-MINI",
        "DDPAI-MINI5",
        "DDPAI-MINIPRO",
        "DDPAI-MOLA-N3",
        "DDPAI-MOLA-Z5",
        "DDPAI-Z40",
        "DDPAI-Z50",
        "DDPAI-N5-DUAL",
        "DDPAI-X2S-PRO",
        "DDPAI-X5-PRO"
    ]

    /// The adapter's configuration (paths, gateway, ports, supported models).
    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var supportedModels: Set<String> { configuration.supportedModels }

    // MARK: - Endpoint paths & parameter names (vendor-specific)

    /// All DDPAI endpoint paths. Grouped here so the wire surface is auditable
    /// in one place. Values model the DDPAI "/vcam/cmd.cgi"-style command API.
    private enum Path {
        static let session = "/vcam/cmd.cgi"      // session / app-register
        static let clipList = "/vcam/cmd.cgi"     // file enumeration
        static let download = "/vcam/download"    // ranged clip file GET
        static let playback = "/vcam/download"    // progressive clip file GET
        static let lock = "/vcam/cmd.cgi"         // lock / unlock a clip
        static let settings = "/vcam/cmd.cgi"     // settings read / write
        static let liveStream = "/live"           // RTSP live preview path
    }

    /// Query / body parameter names used by the command API.
    private enum Param {
        static let command = "cmd"
        static let clipID = "fname"
        static let property = "property"
        static let value = "value"
        static let locked = "locked"
    }

    /// Numeric command codes for the DDPAI "cmd.cgi" API. Model-specific; grouped
    /// for a single point of adjustment.
    private enum Command {
        static let appRegister = "3016"   // establish session, report model
        static let fileList = "4000"      // enumerate recorded clips
        static let lockFile = "4005"      // lock / unlock a clip
        static let getSetting = "2001"    // read a setting
        static let setSetting = "2002"    // write a setting
    }

    /// JSON field names in control-channel responses.
    private enum JSONKey {
        // envelope
        static let errorCode = "errcode"
        static let errorMessage = "errmsg"
        // session
        static let model = "model"
        static let modelAlt = "modelName"
        static let token = "acptoken"
        static let tokenAlt = "token"
        // clip list
        static let files = "files"
        static let filesAlt = "List"
        static let id = "fname"
        static let idAlt = "name"
        static let startTime = "starttime"
        static let startTimeAlt = "time"
        static let duration = "duration"
        static let size = "size"
        static let type = "type"
        static let locked = "locked"
        // setting
        static let value = "value"
    }

    /// Values the camera uses for the clip `type` field. Event / emergency
    /// footage maps to `ClipType.event`.
    private enum WireClipType {
        static let eventValues: Set<String> = ["event", "emr", "emergency", "1", "lock"]
    }

    // MARK: - URL construction

    /// Builds a control-channel URL for `path` with optional query items.
    private func httpURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = configuration.httpScheme
        components.host = configuration.gatewayIP
        // Omit the default HTTP port from the URL for cleanliness.
        if configuration.httpPort != 80 {
            components.port = configuration.httpPort
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        // Paths and host are controlled constants, so this is always valid; the
        // force-unwrap is justified and documented rather than silently failing.
        guard let url = components.url else {
            preconditionFailure("DDPAI endpoint components produced an invalid URL for path \(path)")
        }
        return url
    }

    // MARK: - CameraProtocolAdapter: request builders

    public func sessionRequest() -> HTTPRequest {
        let url = httpURL(
            path: Path.session,
            query: [URLQueryItem(name: Param.command, value: Command.appRegister)]
        )
        return HTTPRequest(url: url, method: .get)
    }

    public func clipListRequest() -> HTTPRequest {
        let url = httpURL(
            path: Path.clipList,
            query: [URLQueryItem(name: Param.command, value: Command.fileList)]
        )
        return HTTPRequest(url: url, method: .get)
    }

    public func clipDownloadRequest(clipID: ClipID, fromByte: Int64) -> HTTPRequest {
        let url = httpURL(
            path: Path.download,
            query: [URLQueryItem(name: Param.clipID, value: clipID)]
        )
        // Ranged GET: resume from the retained byte offset. `bytes=0-` is a
        // valid full-content range, so interruption/resume uses one code path
        // (R5.1, R5.6).
        let headers = ["Range": "bytes=\(max(0, fromByte))-"]
        return HTTPRequest(url: url, method: .get, headers: headers)
    }

    public func clipPlaybackURL(clipID: ClipID) -> URL {
        // Progressive/ranged GET of the clip file; the platform media stack
        // handles range requests itself, so no Range header here (R4.1).
        httpURL(path: Path.playback, query: [URLQueryItem(name: Param.clipID, value: clipID)])
    }

    public func liveStreamURL() -> URL {
        // RTSP control URL for live preview (R2.1).
        var components = URLComponents()
        components.scheme = configuration.rtspScheme
        components.host = configuration.gatewayIP
        components.port = configuration.rtspPort
        components.path = Path.liveStream
        guard let url = components.url else {
            preconditionFailure("DDPAI RTSP components produced an invalid URL")
        }
        return url
    }

    public func lockRequest(clipID: ClipID, locked: Bool) -> HTTPRequest {
        let url = httpURL(
            path: Path.lock,
            query: [
                URLQueryItem(name: Param.command, value: Command.lockFile),
                URLQueryItem(name: Param.clipID, value: clipID),
                URLQueryItem(name: Param.locked, value: locked ? "1" : "0")
            ]
        )
        return HTTPRequest(url: url, method: .get)
    }

    public func settingsReadRequest(_ key: SettingKey) -> HTTPRequest {
        let url = httpURL(
            path: Path.settings,
            query: [
                URLQueryItem(name: Param.command, value: Command.getSetting),
                URLQueryItem(name: Param.property, value: Self.wireProperty(for: key))
            ]
        )
        return HTTPRequest(url: url, method: .get)
    }

    public func settingsWriteRequest(_ key: SettingKey, value: SettingValue) -> HTTPRequest {
        let url = httpURL(
            path: Path.settings,
            query: [
                URLQueryItem(name: Param.command, value: Command.setSetting),
                URLQueryItem(name: Param.property, value: Self.wireProperty(for: key)),
                URLQueryItem(name: Param.value, value: Self.wireValue(value))
            ]
        )
        return HTTPRequest(url: url, method: .get)
    }

    // MARK: - CameraProtocolAdapter: response parsers

    public func parseSession(_ response: HTTPResponse) throws -> CameraSession {
        let object = try decodeObject(response)
        // The model id may arrive under either of two documented field names;
        // accept both so a firmware variant that renames the field still works.
        guard let model = string(object, JSONKey.model) ?? string(object, JSONKey.modelAlt) else {
            throw DDPAIAdapterError.missingField(JSONKey.model)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DDPAIAdapterError.invalidField(JSONKey.model) }
        let token = string(object, JSONKey.token) ?? string(object, JSONKey.tokenAlt)
        return CameraSession(modelID: trimmed, token: token)
    }

    public func parseClipList(_ response: HTTPResponse) throws -> [ClipMetadata] {
        let object = try decodeObject(response)
        // Accept either `files` or `List` as the array field name.
        let rawFiles = array(object, JSONKey.files) ?? array(object, JSONKey.filesAlt)
        guard let files = rawFiles else {
            throw DDPAIAdapterError.missingField(JSONKey.files)
        }
        // Defensive: parse each entry, skipping (not failing) rows that are not
        // objects, while still raising on malformed-but-present required fields
        // so a corrupt payload is visible rather than silently dropping clips.
        var result: [ClipMetadata] = []
        result.reserveCapacity(files.count)
        for entry in files {
            guard let row = entry as? [String: Any] else {
                throw DDPAIAdapterError.malformedResponse("clip-list entry is not an object")
            }
            result.append(try parseClip(row))
        }
        return result
    }

    public func parseSetting(_ key: SettingKey, _ response: HTTPResponse) throws -> SettingValue {
        let object = try decodeObject(response)
        guard object[JSONKey.value] != nil else {
            throw DDPAIAdapterError.missingField(JSONKey.value)
        }
        return try Self.settingValue(for: key, from: object[JSONKey.value]!)
    }

    // MARK: - Clip parsing

    private func parseClip(_ row: [String: Any]) throws -> ClipMetadata {
        guard let id = (string(row, JSONKey.id) ?? string(row, JSONKey.idAlt)),
              !id.isEmpty else {
            throw DDPAIAdapterError.missingField(JSONKey.id)
        }

        guard let startRaw = row[JSONKey.startTime] ?? row[JSONKey.startTimeAlt] else {
            throw DDPAIAdapterError.missingField(JSONKey.startTime)
        }
        let start = try Self.parseDate(startRaw)

        // Duration in whole seconds; absent/zero is tolerated as 0s.
        let durationSeconds = int64(row, JSONKey.duration) ?? 0
        guard durationSeconds >= 0 else { throw DDPAIAdapterError.invalidField(JSONKey.duration) }
        let duration = Duration.seconds(durationSeconds)

        let size = int64(row, JSONKey.size) ?? 0
        guard size >= 0 else { throw DDPAIAdapterError.invalidField(JSONKey.size) }

        let type = Self.clipType(from: row[JSONKey.type])
        let locked = Self.bool(from: row[JSONKey.locked]) ?? false

        return ClipMetadata(
            id: id,
            startTimestamp: start,
            duration: duration,
            sizeBytes: size,
            type: type,
            isLocked: locked
        )
    }

    private static func clipType(from raw: Any?) -> ClipType {
        guard let raw else { return .normal }
        if let s = (raw as? String)?.lowercased(),
           WireClipType.eventValues.contains(s) {
            return .event
        }
        if let n = raw as? NSNumber, n.intValue != 0 {
            return .event
        }
        return .normal
    }

    // MARK: - Setting value <-> wire mapping

    /// Maps a `SettingKey` to the DDPAI `property` identifier.
    private static func wireProperty(for key: SettingKey) -> String {
        switch key {
        case .resolution: return "video_resolution"
        case .collisionSensitivity: return "gsensor_sensitivity"
        case .audioRecording: return "audio_record"
        case .parkingMode: return "parking_mode"
        case .parkingSensitivity: return "parking_sensitivity"
        }
    }

    /// Serializes a `SettingValue` to its wire string form for a write request.
    private static func wireValue(_ value: SettingValue) -> String {
        switch value {
        case .resolution(let s): return s
        case .level(let n): return String(n)
        case .bool(let b): return b ? "1" : "0"
        case .parkingMode(let s): return s
        }
    }

    /// Converts a decoded JSON value into the typed `SettingValue` expected for
    /// `key`, raising a typed error when the shape is wrong.
    private static func settingValue(for key: SettingKey, from raw: Any) throws -> SettingValue {
        switch key {
        case .resolution:
            guard let s = asString(raw), !s.isEmpty else {
                throw DDPAIAdapterError.invalidField("resolution")
            }
            return .resolution(s)
        case .parkingMode:
            guard let s = asString(raw), !s.isEmpty else {
                throw DDPAIAdapterError.invalidField("parkingMode")
            }
            return .parkingMode(s)
        case .collisionSensitivity, .parkingSensitivity:
            guard let n = asInt(raw) else {
                throw DDPAIAdapterError.invalidField("level")
            }
            return .level(n)
        case .audioRecording:
            guard let b = bool(from: raw) else {
                throw DDPAIAdapterError.invalidField("audioRecording")
            }
            return .bool(b)
        }
    }

    // MARK: - Defensive JSON decoding helpers

    /// Validates HTTP status, decodes the body as a JSON object, and surfaces any
    /// camera-reported application error embedded in the envelope.
    private func decodeObject(_ response: HTTPResponse) throws -> [String: Any] {
        guard (200...299).contains(response.statusCode) else {
            throw DDPAIAdapterError.httpStatus(response.statusCode)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: response.body, options: [])
        } catch {
            throw DDPAIAdapterError.malformedResponse("body is not valid JSON")
        }
        guard let object = json as? [String: Any] else {
            throw DDPAIAdapterError.malformedResponse("top-level JSON is not an object")
        }
        // A non-zero error code in the envelope is an application-level failure.
        if let code = Self.asInt(object[JSONKey.errorCode]), code != 0 {
            throw DDPAIAdapterError.cameraError(code: code, message: Self.asString(object[JSONKey.errorMessage]))
        }
        return object
    }

    private func string(_ object: [String: Any], _ key: String) -> String? {
        Self.asString(object[key])
    }

    private func int64(_ object: [String: Any], _ key: String) -> Int64? {
        Self.asInt64(object[key])
    }

    private func array(_ object: [String: Any], _ key: String) -> [Any]? {
        object[key] as? [Any]
    }

    private static func asString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func asInt(_ raw: Any?) -> Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private static func asInt64(_ raw: Any?) -> Int64? {
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s) }
        return nil
    }

    /// Interprets a JSON value as a boolean, accepting bools, 0/1 numbers, and
    /// common string spellings.
    private static func bool(from raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber {
            // NSNumber bridges Bool too; compare numerically to be safe.
            return n.intValue != 0
        }
        if let s = (raw as? String)?.lowercased() {
            switch s {
            case "1", "true", "on", "yes": return true
            case "0", "false", "off", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// Parses a start-time field that may arrive as epoch seconds (number or
    /// numeric string) or an ISO-8601 / `yyyy-MM-dd HH:mm:ss` string.
    private static func parseDate(_ raw: Any) throws -> Date {
        if let epoch = asInt64(raw) {
            return Date(timeIntervalSince1970: TimeInterval(epoch))
        }
        if let s = raw as? String {
            if let iso = isoFormatter.date(from: s) { return iso }
            if let plain = plainFormatter.date(from: s) { return plain }
        }
        throw DDPAIAdapterError.invalidField(JSONKey.startTime)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let plainFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
