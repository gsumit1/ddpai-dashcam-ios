# Implementation Plan: DDPAI Dash Cam Companion (iOS)

## Overview

This plan implements the DDPAI dash cam iOS app in incremental, test-driven order. It builds the foundation (project structure, data models, pure logic), then the Camera Communication Layer behind a mockable `CameraProtocolAdapter`, then the `LibraryStore` persistence layer, then each subsystem service (`Connection_Manager`, `Live_Preview`, `Media_Browser`, `Media_Player`, `Download_Manager`, `Local_Library`, `Settings_Controller`) with its correctness properties, and finally the view models and SwiftUI views wired to the shared `Connection_State`.

Each subsystem's pure, input-varying logic is extracted into free functions / value types with no I/O so the 22 property-based tests (SwiftCheck or swift-testing) can drive it cheaply. Timing bounds and camera I/O are validated with integration and example tests against mocked `CameraProtocolAdapter` / `HTTPControlClient` / `LiveStreamClient`.

Convention: every property test is tagged with a comment of the form `Feature: ddpai-dashcam-ios, Property {number}: {property_text}` and runs a minimum of 100 generated cases.

## Tasks

- [x] 1. Set up project structure, dependencies, and core data models
  - [x] 1.1 Create the Xcode project skeleton and layered folder structure
    - Create an iOS app target (Swift 5.9+, SwiftUI) with folders: `Models`, `CameraComm`, `Persistence`, `Subsystems`, `ViewModels`, `Views`, plus `Tests` and `PropertyTests`
    - Add Swift Package dependencies: GRDB (persistence) and SwiftCheck (property-based testing); configure the test targets to link them
    - _Requirements: 1.1_

  - [x] 1.2 Define core data model types
    - Implement `ConnectionState`, `ClipType`, `ClipID`, `ClipMetadata` (with computed `isProtected`), `StoredClip`, `ClipFilter`, `DownloadStatus`, `DownloadTask`, `SettingKey`, `SettingValue`, `SettingState`, `SettingAvailability`, and `WriteOutcome` as `Equatable` value types in `Models`
    - _Requirements: 3.3, 3.4, 5.2, 5.4, 5.5, 5.8, 6.2, 6.8_

- [x] 2. Implement pure formatting, ordering, and filtering logic with property tests
  - [x] 2.1 Implement duration/size formatting and clip ordering/filtering functions
    - Write pure `formatDuration` (H:M:S), `megabytes(fromBytes:)`, `orderByStartDescending`, `apply(filter:)`, and clip indicator mapping (type/protection) as free functions over `ClipMetadata`
    - _Requirements: 3.3, 3.4, 3.5, 3.6, 3.7, 4.3, 6.1, 6.2, 7.2_

  - [ ]* 2.2 Write property test for clip ordering
    - **Property 4: Clips are ordered by recording start timestamp descending**
    - **Validates: Requirements 3.7, 3.5, 7.2**

  - [ ]* 2.3 Write property test for clip filtering
    - **Property 5: Clip filtering is sound, complete, and order-preserving**
    - **Validates: Requirements 3.5, 3.6, 6.2**

  - [ ]* 2.4 Write property test for clip indicators
    - **Property 6: Clip indicators reflect type and protection**
    - **Validates: Requirements 3.4, 6.1**

  - [ ]* 2.5 Write property test for duration/size formatting
    - **Property 7: Duration formatting round-trips and size formatting is consistent**
    - **Validates: Requirements 3.3, 4.3**

- [x] 3. Implement pure decision/arithmetic logic with property tests
  - [x] 3.1 Implement model-support, retry, clamping, source-selection, progress, queue, interrupt/resume, storage, and settings decision functions
    - Write pure functions: `isModelSupported(_:in:)`, bounded `retryLoop`, `clamp(_:to:)`, `playbackSource(for:connectionState:isLocal:)`, `progressPercent(completed:total:)`, `enqueueOrder(_:cap:)`, `interrupt(task:)`, `resumeRequest(task:connectionState:)`, `hasSufficientStorage(available:clipSize:reserve:)`, `controlAvailability(for:)`, `pendingDisable(_:)`, `applyOrRevert(previous:outcome:)`, `reconcile(displayed:cameraReported:)`, and `toggle(_:)`
    - _Requirements: 1.6, 1.8, 1.9, 4.2, 4.6, 4.7, 5.2, 5.4, 5.5, 5.6, 5.7, 5.8, 6.5, 6.6, 6.7, 8.4, 8.5, 8.6, 9.4, 9.5, 10.3, 10.4, 10.5, 10.6, 11.3, 11.4, 11.6, 11.7, 12.2, 12.3, 12.4_

  - [ ]* 3.2 Write property test for model-support decision
    - **Property 1: Camera model support decision**
    - **Validates: Requirements 1.6**

  - [ ]* 3.3 Write property test for bounded retry
    - **Property 2: Bounded retry stops at the limit and on first success**
    - **Validates: Requirements 1.8, 1.9, 12.2**

  - [ ]* 3.4 Write property test for value clamping
    - **Property 8: Values are clamped to their supported range**
    - **Validates: Requirements 4.2, 11.4**

  - [ ]* 3.5 Write property test for playback source selection
    - **Property 9: Playback source selection**
    - **Validates: Requirements 4.6, 4.7**

  - [ ]* 3.6 Write property test for download progress percent
    - **Property 10: Download progress percent is bounded and monotonic**
    - **Validates: Requirements 5.2**

  - [ ]* 3.7 Write property test for queue ordering and cap
    - **Property 11: Download queue preserves selection order within the cap**
    - **Validates: Requirements 5.4**

  - [ ]* 3.8 Write property test for interruption byte retention
    - **Property 12: Interruption retains the completed byte count**
    - **Validates: Requirements 5.5**

  - [ ]* 3.9 Write property test for resume gating
    - **Property 13: Resume continues from the retained offset only when connected**
    - **Validates: Requirements 5.6, 5.7**

  - [ ]* 3.10 Write property test for storage sufficiency
    - **Property 14: Storage sufficiency honors the reserve margin**
    - **Validates: Requirements 5.8**

  - [ ]* 3.11 Write property test for settings control availability
    - **Property 18: Settings control availability tracks connection state**
    - **Validates: Requirements 8.5, 10.6, 11.7**

  - [ ]* 3.12 Write property test for pending-write disable
    - **Property 19: A pending write disables its control**
    - **Validates: Requirements 8.6**

  - [ ]* 3.13 Write property test for apply/revert on write outcome
    - **Property 20: Writes apply on acceptance and revert on any non-acceptance**
    - **Validates: Requirements 12.4, 8.4, 9.4, 9.5, 10.4, 10.5, 11.3, 11.6, 6.5, 6.7**

  - [ ]* 3.14 Write property test for display convergence
    - **Property 21: Display converges to the camera-reported value**
    - **Validates: Requirements 12.3**

  - [ ]* 3.15 Write property test for audio toggle round-trip
    - **Property 22: Audio recording toggle inverts and round-trips**
    - **Validates: Requirements 10.3**

- [x] 4. Checkpoint - pure logic validated
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Implement the Camera Communication Layer with a mockable adapter
  - [x] 5.1 Define communication protocols and wire types
    - Write `CameraProtocolAdapter`, `HTTPControlClient`, and `LiveStreamClient` protocols plus `HTTPRequest`, `HTTPResponse`, `CameraSession`, `DownloadProgress`, `LiveStreamHandle`, and `DecodedFrame` types in `CameraComm`
    - _Requirements: 1.2, 1.3, 1.6_

  - [x] 5.2 Implement the DDPAI `CameraProtocolAdapter`
    - Encapsulate all DDPAI endpoint paths, parameter names, stream URL formats, and `supportedModels`; implement session/clip-list/download/playback/live/lock/settings request builders and response parsers
    - _Requirements: 1.3, 1.6, 3.1, 4.1, 5.1, 6.4, 6.6, 8.1, 9.1, 10.1, 11.1, 11.4_

  - [x] 5.3 Implement `URLSessionHTTPControlClient` with bounded timeouts and ranged download
    - Implement `send(_:timeout:)` using `URLSession` with Swift Concurrency cancellation, and `download(_:to:resumingFrom:)` as an `AsyncThrowingStream` emitting ranged-GET progress
    - _Requirements: 1.2, 1.5, 3.1, 3.9, 4.4, 5.1, 5.2, 5.6_

  - [x] 5.4 Implement `AVFoundationLiveStreamClient`
    - Implement RTSP/RTP session control (DESCRIBE/SETUP/PLAY/PAUSE/TEARDOWN), H.264 frame delivery via `AsyncStream<DecodedFrame>`, `audioAvailable`, and `setAudioMuted`
    - _Requirements: 2.1, 2.5, 2.6_

  - [x] 5.5 Implement in-memory mock adapter and clients for tests
    - Write `MockCameraProtocolAdapter`, `MockHTTPControlClient`, and `MockLiveStreamClient` with programmable responses, delays, and failures for use by subsystem and integration tests
    - _Requirements: 1.2, 1.5, 1.6_

  - [ ]* 5.6 Write integration tests for the communication layer
    - Test connect success/timeout against the mock, ranged download progress emission, and live stream session lifecycle timing
    - _Requirements: 1.2, 1.5, 2.1, 2.2, 5.1, 5.2_

- [x] 6. Implement the persistence layer (`LibraryStore` / GRDB)
  - [x] 6.1 Implement the GRDB schema and `LibraryStore`
    - Create `stored_clip` and `download_task` tables and migrations; implement CRUD for stored clips and download tasks, storing media in `Application Support/clips/<id>.mp4` with relative paths persisted
    - _Requirements: 5.3, 5.5, 6.8, 7.1, 7.2, 7.4_

  - [ ]* 6.2 Write unit tests for `LibraryStore`
    - Test insert/query/delete round-trips, relative-path resolution, and offline queryability of sort/filter
    - _Requirements: 7.1, 7.2, 7.4_

- [x] 7. Implement `Connection_Manager`
  - [x] 7.1 Implement `ConnectionManaging` with session, timeout, model check, and reconnection
    - Own the observable `Connection_State`; require hotspot join (via `NWPathMonitor`); enforce 10s connect timeout; validate model against `supportedModels`; detect link loss within 5s; run up to 3 auto-reconnect attempts (10s each) using the bounded retry function; fall back to disconnected on exhaustion
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9_

  - [ ]* 7.2 Write example tests for connection state labels and messages
    - Test state-label exposure (R1.1), model-id display (R1.3), and join instruction when not on hotspot (R1.4)
    - _Requirements: 1.1, 1.3, 1.4_

  - [ ]* 7.3 Write integration tests for connection timing
    - Test connect-within-10s and timeout→disconnected, link-loss detection within 5s, auto-reconnect timing and exhaustion→disconnected
    - _Requirements: 1.2, 1.3, 1.5, 1.7, 1.8, 1.9_

- [x] 8. Implement `Live_Preview`
  - [x] 8.1 Implement `LivePreviewing` observing Connection_State
    - Implement `open` (first frame within 5s else unavailable+retry), `close` (teardown on leave), `setAudioMuted` gated on `audioAvailable`, and stop-rendering-within-2s on interrupted/disconnected using the shared Connection_State; surface resolution and signal indicator while rendering
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7_

  - [ ]* 8.2 Write property test for render-only-while-connected
    - **Property 3: Live preview renders only while connected**
    - **Validates: Requirements 2.4**

  - [ ]* 8.3 Write example tests for live preview UI behaviors
    - Test rendering-state exposes resolution/signal indicator (R2.3), teardown on leaving (R2.5), mute control gated on audio availability (R2.6)
    - _Requirements: 2.3, 2.5, 2.6_

  - [ ]* 8.4 Write integration tests for live preview timing
    - Test first frame within 5s and latency within 2s, and no-frame→unavailable+retry
    - _Requirements: 2.1, 2.2, 2.7_

- [x] 9. Implement `Media_Browser`
  - [x] 9.1 Implement `MediaBrowsing` with retrieval, ordering, filtering, and flags
    - Implement `load` (15s timeout), raw metadata retrieval via `HTTPControlClient`, pure ordering/filtering application, downloaded-flag join from `LibraryStore` and protected-flag from metadata, and load-state handling (loading/loaded/empty/failed/connectionLost) reacting to Connection_State
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 6.1, 6.2, 6.3_

  - [ ]* 9.2 Write example tests for browser states and messages
    - Test loading indicator during retrieval (R3.2), empty-library message with zero rows (R3.8), no-matching-clips message (R3.6), no-emergency-footage message (R6.3)
    - _Requirements: 3.2, 3.6, 3.8, 6.3_

  - [ ]* 9.3 Write integration tests for browser retrieval timing
    - Test retrieval within 15s (R3.1), timeout (R3.9), and disconnect mid-retrieval (R3.10)
    - _Requirements: 3.1, 3.9, 3.10_

- [x] 10. Implement `Media_Player`
  - [x] 10.1 Implement `MediaPlaying` with source selection and controls
    - Implement `play` using the pure source-selection decision (local if present, else stream if connected, else unavailable), `pause`, `seek` clamped to `0...duration`, position/duration display, start-within-10s timeout handling, and retry
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7_

  - [ ]* 10.2 Write example test for playback retry
    - Test retry re-invokes playback (R4.5)
    - _Requirements: 4.5_

  - [ ]* 10.3 Write integration tests for playback timing
    - Test playback starts within 3s (R4.1) and start-timeout branch (R4.4)
    - _Requirements: 4.1, 4.4_

- [x] 11. Implement `Download_Manager`
  - [x] 11.1 Implement the `DownloadManager` actor with sequential queue and resume
    - Implement `enqueue` (max 100, preserving selection order), sequential processing, per-clip storage check against size + 50 MB reserve, interrupt handling (mark incomplete, retain completed bytes), `resume` from retained offset when connected, `cancel` (stop within 2s, remove partial), progress `AsyncStream` with integer % at ≤1s cadence, and on-completion store + downloaded flag carrying the protected flag
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 6.8_

  - [ ]* 11.2 Write property test for protection preserved on store
    - **Property 16: Protection is preserved when a clip is stored**
    - **Validates: Requirements 6.8**

  - [ ]* 11.3 Write example tests for download completion and cancel cleanup
    - Test completion stores clip + sets downloaded flag (R5.3), cancel removes partial file (R5.9 cleanup)
    - _Requirements: 5.3, 5.9_

  - [ ]* 11.4 Write integration tests for download timing
    - Test end-to-end transfer and storage (R5.1), progress cadence ≤1s (R5.2), cancel stops within 2s (R5.9 timing)
    - _Requirements: 5.1, 5.2, 5.9_

- [x] 12. Implement `Local_Library`
  - [x] 12.1 Implement `LocalLibrary` over `LibraryStore`
    - Implement `allClips` (sorted desc by start timestamp), `contains`, `delete` (retain + message on failure), and `fileURL(for:)`, available regardless of Connection_State
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

  - [ ]* 12.2 Write property test for delete invariant
    - **Property 17: Deleting a Local_Library clip removes only that clip**
    - **Validates: Requirements 7.4**

  - [ ]* 12.3 Write example tests for local library behaviors
    - Test offline display (R7.1), empty message (R7.3), delete-failure retains clip + message (R7.5)
    - _Requirements: 7.1, 7.3, 7.5_

- [x] 13. Implement `Settings_Controller`
  - [x] 13.1 Implement `SettingsControlling` with sync, read/write, and lock
    - Implement `syncAll` (loading→values, retry cap of 3), `readSetting`, `writeSetting` and `lock` using the optimistic-with-revert pattern (snapshot previous, disable while pending, apply on acceptance, revert on reject/timeout/disconnect), convergence to camera-reported values, and availability gated on Connection_State across resolution, collision sensitivity, audio, and parking mode/sensitivity
    - _Requirements: 6.4, 6.5, 6.6, 6.7, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7, 12.1, 12.2, 12.3, 12.4_

  - [ ]* 13.2 Write property test for lock/unlock round-trip
    - **Property 15: Lock then unlock is a protection round-trip**
    - **Validates: Requirements 6.6**

  - [ ]* 13.3 Write example tests for settings interactions
    - Test in-progress indicator on selection (R9.2), audio retrieve/display and toggle issuing the requested write (R10.1, R10.2)
    - _Requirements: 9.2, 10.1, 10.2_

  - [ ]* 13.4 Write integration tests for settings timing and write paths
    - Test settings retrieval timing/failure (R8.1, R8.2, R12.1), accepted/rejected/timeout write paths across resolution/collision/parking (R8.3, R8.4, R9.1–9.5, R11.1–11.6), lock/unlock confirm timing and failure branches (R6.4–6.7), sync retry cap of 3 (R12.2), convergence timing (R12.3)
    - _Requirements: 6.4, 6.5, 6.6, 6.7, 8.1, 8.2, 8.3, 8.4, 9.1, 9.2, 9.3, 9.4, 9.5, 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 12.1, 12.2, 12.3_

- [x] 14. Checkpoint - all subsystems validated
  - Ensure all tests pass, ask the user if questions arise.

- [x] 15. Implement view models (MVVM) wired to Connection_State
  - [x] 15.1 Implement connection, live preview, and media browser view models
    - Create `ConnectionViewModel`, `LivePreviewViewModel`, and `MediaBrowserViewModel` exposing observable state derived from their subsystems and the shared `Connection_State`
    - _Requirements: 1.1, 2.3, 2.4, 3.1, 3.2, 3.5, 3.6, 3.8_

  - [x] 15.2 Implement player, download, local library, and settings view models
    - Create `MediaPlayerViewModel`, `DownloadViewModel`, `LocalLibraryViewModel`, and `SettingsViewModel` exposing observable state and user intents to their subsystems
    - _Requirements: 4.2, 4.3, 5.2, 5.4, 7.2, 8.1, 9.1, 10.1, 11.1, 12.1_

- [x] 16. Implement SwiftUI views and wire the app together
  - [x] 16.1 Implement connection, live preview, and media browser views
    - Build `ConnectionView`, `LivePreviewView` (resolution + signal indicator, mute control, retry), and `MediaBrowserView` (clip rows with type/protected indicators, filters, loading/empty/failed states), bound to their view models
    - _Requirements: 1.1, 1.3, 1.4, 2.3, 2.6, 2.7, 3.3, 3.4, 3.5, 3.6, 3.8, 6.1, 6.3_

  - [x] 16.2 Implement player, download/queue, local library, and settings views
    - Build `MediaPlayerView` (play/pause/seek, position/duration), `DownloadQueueView` (progress, interrupted/resume status), `LocalLibraryView` (share sheet, photo-library export with permission handling), and `SettingsViews` (resolution, collision sensitivity, audio toggle, parking mode/sensitivity with in-progress/disabled states), bound to their view models
    - _Requirements: 4.2, 4.3, 5.2, 5.5, 5.7, 5.8, 7.2, 7.6, 7.7, 7.8, 8.1, 8.5, 8.6, 9.2, 10.1, 11.1, 11.4, 11.7_

  - [x] 16.3 Compose the app entry point and dependency wiring
    - Build the app root that instantiates `Connection_Manager` (owning the shared `Connection_State`), the concrete communication layer, `LibraryStore`, all subsystems, and the navigation shell connecting the screens
    - _Requirements: 1.1, 7.1_

  - [ ]* 16.4 Write example tests for view-layer photo/share behaviors
    - Test share sheet presentation (R7.6), photo-export granted path (R7.7), and denied message (R7.8)
    - _Requirements: 7.6, 7.7, 7.8_

- [x] 17. Final checkpoint - full app wired and tests passing
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional (test sub-tasks) and can be skipped for a faster MVP, though the property tests are the primary guarantee of the 22 correctness properties.
- Each property test is tagged `Feature: ddpai-dashcam-ios, Property {number}: {property_text}` and runs ≥100 generated cases (SwiftCheck or swift-testing).
- The Camera Communication Layer and `LibraryStore` are protocols, mocked in tests, so pure logic and subsystems are testable without a physical camera.
- Timing-bound and I/O criteria are covered by integration tests; UI/edge criteria by example tests; input-varying criteria by Properties 1–22.
- Checkpoints provide incremental validation at natural boundaries (pure logic, subsystems, full wiring).

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["2.1", "3.1", "5.1"] },
    { "id": 3, "tasks": ["2.2", "2.3", "2.4", "2.5", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8", "3.9", "3.10", "3.11", "3.12", "3.13", "3.14", "3.15", "5.2", "5.5", "6.1"] },
    { "id": 4, "tasks": ["5.3", "5.4", "6.2"] },
    { "id": 5, "tasks": ["5.6", "7.1"] },
    { "id": 6, "tasks": ["7.2", "7.3", "8.1", "9.1", "10.1", "11.1", "12.1", "13.1"] },
    { "id": 7, "tasks": ["8.2", "8.3", "8.4", "9.2", "9.3", "10.2", "10.3", "11.2", "11.3", "11.4", "12.2", "12.3", "13.2", "13.3", "13.4"] },
    { "id": 8, "tasks": ["15.1", "15.2"] },
    { "id": 9, "tasks": ["16.1", "16.2"] },
    { "id": 10, "tasks": ["16.3"] },
    { "id": 11, "tasks": ["16.4"] }
  ]
}
```
