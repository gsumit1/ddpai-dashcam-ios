// DDPAIDashcam
//
// DDPAI dash cam companion app for iOS.
//
// Technology stack (see design.md): Swift 5.9+, SwiftUI, MVVM + unidirectional
// state, Swift Concurrency (async/await, actors, AsyncStream), URLSession for
// HTTP, AVFoundation for live/clip playback, GRDB for local persistence,
// NWPathMonitor for reachability.
//
// Layered module layout:
//   Models/      - domain value types (no I/O)
//   CameraComm/  - Camera Communication Layer (DDPAI wire details isolated)
//   Persistence/ - LibraryStore (SQLite via GRDB) + app-container media files
//   Subsystems/  - subsystem services + pure decision logic
//   ViewModels/  - MVVM view models
//   Views/       - SwiftUI views
//
// The shared Connection_State owned by Connection_Manager is the single source
// of truth every subsystem observes.

/// Marker for the DDPAIDashcam module. Replaced/extended by concrete types as
/// subsequent tasks are implemented.
public enum DDPAIDashcam {
    /// Human-readable module name.
    public static let moduleName = "DDPAIDashcam"
}
