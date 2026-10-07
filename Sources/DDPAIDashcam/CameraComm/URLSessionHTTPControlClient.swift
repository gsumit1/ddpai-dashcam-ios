// URLSessionHTTPControlClient
//
// Task 5.3: the concrete `HTTPControlClient` for real camera I/O. It executes
// the protocol-neutral `HTTPRequest` values built by `DDPAICameraProtocolAdapter`
// over `URLSession`, without knowing any DDPAI-specific wire details.
//
// Two responsibilities:
//
//   • `send(_:timeout:)` — a bounded request/response call. The caller supplies
//     the governing requirement's timeout (10s connect R1.2/R1.5, 15s clip list
//     R3.1/R3.9, 10s playback-start R4.4, etc.). The bound is enforced with
//     Swift Concurrency: the request races a `Task.sleep` timer in a task group
//     and whichever loses is cancelled. External task cancellation (e.g. a
//     disconnect tearing down the caller) propagates straight through, matching
//     the design's "single timeout mechanism / Connection_State is
//     authoritative" rules.
//
//   • `download(_:to:resumingFrom:)` — a ranged, resumable transfer (R5.1,
//     R5.2, R5.6). The adapter's `clipDownloadRequest` already sets
//     `Range: bytes=<from>-`; this client honors the resume offset by appending
//     to the destination file from `byte`, streams the body with the
//     `URLSession.bytes` async API, and emits `DownloadProgress` as bytes
//     arrive. Cancelling the consuming task stops the transfer promptly (R5.9).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

/// Typed transport-level failures raised by `URLSessionHTTPControlClient`.
///
/// These describe the HTTP transport, not the camera's application protocol
/// (which `DDPAICameraProtocolAdapter` surfaces as `DDPAIAdapterError`). Keeping
/// them distinct lets callers tell "the call didn't complete in time" (R1.5,
/// R3.9, R4.4) apart from "the camera answered with an error payload".
public enum HTTPControlClientError: Error, Equatable {
    /// The call did not complete within the caller-supplied timeout bound.
    case timedOut(Duration)
    /// The response was not an HTTP response (no status line available).
    case nonHTTPResponse
    /// Writing downloaded bytes to the destination file failed.
    case fileWriteFailed(String)
    /// The destination file could not be prepared for the requested resume
    /// offset (e.g. resuming past the end of a shorter existing file).
    case invalidResumeOffset(Int64)
}

// MARK: - Client

/// `HTTPControlClient` backed by `URLSession`.
///
/// `Sendable` and cheap to construct: it holds only an immutable `URLSession`,
/// so a single instance can be shared across subsystems. The session is created
/// with per-resource timeouts disabled because this client enforces timeouts
/// itself via structured concurrency, giving one deterministic, cancellable
/// mechanism for every requirement bound.
public final class URLSessionHTTPControlClient: HTTPControlClient, Sendable {

    private let session: URLSession

    /// Creates a client over an existing session (inject a configured session
    /// in tests or to tune the transport).
    public init(session: URLSession) {
        self.session = session
    }

    /// Creates a client with a session suited to on-hotspot camera I/O: no
    /// URL-cache (clip bytes and settings are not cacheable), and URLSession's
    /// own timeouts set generously high so this client's structured-concurrency
    /// bound is the single source of truth for timing out a call.
    public convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        // Keep URLSession from timing out before our own bound does; we race the
        // request against an explicit Task.sleep instead.
        configuration.timeoutIntervalForRequest = TimeInterval.greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        configuration.waitsForConnectivity = false
        self.init(session: URLSession(configuration: configuration))
    }

    // MARK: - send

    /// Executes `request`, enforcing `timeout` with Swift Concurrency.
    ///
    /// The network call and a timeout timer run as two children of a throwing
    /// task group; the first to finish wins and the group cancels the other. If
    /// the timer wins, the in-flight request is cancelled and
    /// `HTTPControlClientError.timedOut` is thrown. If the surrounding task is
    /// cancelled (e.g. the caller disconnects), that cancellation propagates and
    /// a `CancellationError` is thrown — never a stale success.
    public func send(_ request: HTTPRequest, timeout: Duration) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let urlRequest = Self.makeURLRequest(from: request)

        return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask { [session] in
                let (data, response) = try await session.data(for: urlRequest)
                try Task.checkCancellation()
                return try Self.makeHTTPResponse(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HTTPControlClientError.timedOut(timeout)
            }

            defer { group.cancelAll() }
            // The first child to finish — the response or the timeout — decides
            // the outcome; `cancelAll` in the defer stops the loser.
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    // MARK: - download

    /// Streams a ranged GET to `fileURL`, resuming from `byte`, emitting
    /// progress as the body arrives.
    ///
    /// The returned stream drives the whole transfer: a backing task opens the
    /// destination file (truncating to the resume offset so a partial file is
    /// continued, not duplicated), reads the response body with
    /// `URLSession.bytes`, appends each chunk, and yields `DownloadProgress`.
    /// Finishing the stream (or cancelling the consumer) cancels that task,
    /// which stops the read and closes the file — so interruption halts the
    /// transfer promptly (R5.9).
    public func download(
        _ request: HTTPRequest,
        to fileURL: URL,
        resumingFrom byte: Int64
    ) -> AsyncThrowingStream<DownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runDownload(
                        request,
                        to: fileURL,
                        resumingFrom: byte,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // When the consumer stops iterating (break, cancellation, or
            // deinit), tear down the backing transfer.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Performs the resumable transfer that backs `download`. Separated out so
    /// the stream wrapper stays a thin adapter around structured async code.
    private func runDownload(
        _ request: HTTPRequest,
        to fileURL: URL,
        resumingFrom byte: Int64,
        continuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation
    ) async throws {
        let resumeOffset = max(0, byte)
        let urlRequest = Self.makeURLRequest(from: request)

        let handle = try Self.prepareDestination(fileURL, resumingFrom: resumeOffset)
        defer { try? handle.close() }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPControlClientError.nonHTTPResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPControlClientError.fileWriteFailed(
                "unexpected status \(httpResponse.statusCode)"
            )
        }

        // Total size, when known: a 206 Partial Content reports the remaining
        // range length, so add the resume offset back to get the clip's full
        // size; a 200 reports the whole length directly. `-1` means unknown.
        let totalBytes = Self.totalBytes(
            from: httpResponse,
            resumeOffset: resumeOffset
        )

        var completed = resumeOffset
        // Emit an initial progress point so a resumed download immediately
        // reflects the retained byte count (R5.6).
        continuation.yield(DownloadProgress(completedBytes: completed, totalBytes: totalBytes))

        // Buffer bytes and flush in chunks to avoid a syscall per byte while
        // still surfacing progress promptly.
        var buffer = Data()
        buffer.reserveCapacity(Self.flushThreshold)

        for try await byteValue in bytes {
            try Task.checkCancellation()
            buffer.append(byteValue)
            if buffer.count >= Self.flushThreshold {
                try Self.write(buffer, to: handle)
                completed += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                continuation.yield(
                    DownloadProgress(completedBytes: completed, totalBytes: totalBytes)
                )
            }
        }

        try Task.checkCancellation()
        if !buffer.isEmpty {
            try Self.write(buffer, to: handle)
            completed += Int64(buffer.count)
        }
        // Final progress point reflects the fully written transfer.
        continuation.yield(DownloadProgress(completedBytes: completed, totalBytes: totalBytes))
    }

    // MARK: - Tuning

    /// Flush accumulated download bytes to disk (and emit progress) once this
    /// many bytes have buffered. 64 KiB balances syscall overhead against
    /// progress-update cadence.
    private static let flushThreshold = 64 * 1024

    // MARK: - Request / response mapping

    /// Builds a `URLRequest` from the protocol-neutral `HTTPRequest`.
    private static func makeURLRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    /// Maps a `URLSession` result into the protocol-neutral `HTTPResponse`.
    private static func makeHTTPResponse(
        data: Data,
        response: URLResponse
    ) throws -> HTTPResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPControlClientError.nonHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let name = key as? String, let stringValue = value as? String {
                headers[name] = stringValue
            }
        }
        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }

    /// Computes the clip's full size in bytes from the response, or `-1` when
    /// the camera does not report a length.
    private static func totalBytes(
        from response: HTTPURLResponse,
        resumeOffset: Int64
    ) -> Int64 {
        let expected = response.expectedContentLength
        guard expected != NSURLSessionTransferSizeUnknown, expected >= 0 else {
            return -1
        }
        // A 206 Partial Content body carries only the remaining range, so the
        // full clip size is the remaining length plus what we already have.
        if response.statusCode == 206 {
            return resumeOffset + expected
        }
        return expected
    }

    // MARK: - File handling

    /// Opens `fileURL` for writing positioned at `resumeOffset`.
    ///
    /// A fresh download (offset 0) creates/truncates the file. A resume keeps
    /// the existing partial bytes, truncates anything past the offset (so a
    /// previously over-written file can't duplicate data), and seeks to the
    /// offset to append. Resuming past the end of a shorter file is rejected.
    private static func prepareDestination(
        _ fileURL: URL,
        resumingFrom resumeOffset: Int64
    ) throws -> FileHandle {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        if resumeOffset == 0 {
            // Fresh transfer: start from an empty file.
            fileManager.createFile(atPath: fileURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                throw HTTPControlClientError.fileWriteFailed(fileURL.path)
            }
            try handle.truncate(atOffset: 0)
            return handle
        }

        // Resume: the partial file must already hold at least `resumeOffset`
        // bytes, otherwise the retained byte count is inconsistent with disk.
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw HTTPControlClientError.invalidResumeOffset(resumeOffset)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw HTTPControlClientError.fileWriteFailed(fileURL.path)
        }
        let existingSize = (try? handle.seekToEnd()) ?? 0
        guard existingSize >= UInt64(resumeOffset) else {
            try? handle.close()
            throw HTTPControlClientError.invalidResumeOffset(resumeOffset)
        }
        // Drop anything beyond the resume point, then position to append.
        try handle.truncate(atOffset: UInt64(resumeOffset))
        try handle.seek(toOffset: UInt64(resumeOffset))
        return handle
    }

    /// Appends `data` to the open file handle, mapping any failure to a typed
    /// error.
    private static func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw HTTPControlClientError.fileWriteFailed(error.localizedDescription)
        }
    }
}
