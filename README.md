# DDPAI Dash Cam Companion (iOS)

Native iOS companion app for DDPAI dash cameras: live preview, playback/download
of recorded footage, and remote control of camera settings over the camera's
Wi-Fi hotspot.

Spec: `.kiro/specs/ddpai-dashcam-ios/` (requirements.md, design.md, tasks.md).

## Technology stack

- Swift 5.9+ (toolchain here is Swift 6.3)
- SwiftUI, MVVM + unidirectional state
- Swift Concurrency (async/await, actors, `AsyncStream`)
- `URLSession` (HTTP, ranged GET), `AVFoundation` (live/clip playback),
  `NWPathMonitor` (reachability)
- Persistence: SQLite via [GRDB](https://github.com/groue/GRDB.swift) (`7.11.1`)
- Property-based testing: [SwiftCheck](https://github.com/typelift/SwiftCheck) (`0.12.0`)

## Project layout

This is a Swift Package (`Package.swift`) that opens directly in Xcode and
builds from the command line. The feature code lives in a library target so the
pure logic, subsystems, and view models are testable without a device; the iOS
`@main` app shell is layered on top in a later task.

```
Package.swift
Sources/DDPAIDashcam/
  Models/        domain value types (no I/O)
  CameraComm/    Camera Communication Layer (DDPAI wire details isolated)
  Persistence/   LibraryStore (SQLite via GRDB) + app-container media files
  Subsystems/    subsystem services + pure decision logic
  ViewModels/    MVVM view models
  Views/         SwiftUI views
Tests/
  Tests/         example / unit tests (XCTest)
  PropertyTests/ property-based tests (SwiftCheck), each tagged
                 `Feature: ddpai-dashcam-ios, Property {n}: {text}`, ≥100 cases
```

The shared `Connection_State` owned by `Connection_Manager` is the single source
of truth every subsystem observes.

## Building and testing

```sh
swift build          # builds the DDPAIDashcam library + GRDB
swift test           # runs the XCTest + SwiftCheck test targets
```

Note on this environment: only the Command Line Tools are installed
(`xcode-select -p` → `/Library/Developer/CommandLineTools`), which does not ship
the `XCTest` framework. `swift build` succeeds (library + GRDB), but `swift test`
and the SwiftCheck target require a full Xcode installation to supply `XCTest`.
Running the test targets needs Xcode.app selected via
`sudo xcode-select -s /Applications/Xcode.app` (or an Xcode CI runner).
