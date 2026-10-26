# DDPAI Dash Cam Companion (iOS)

Native iOS companion app for DDPAI dash cameras: live preview, playback/download
of recorded footage, and remote control of camera settings over the camera
Wi-Fi hotspot.

Spec: `.kiro/specs/ddpai-dashcam-ios/` (requirements.md, design.md, tasks.md).

## Running the app (iPhone simulator)

The feature code is a Swift Package (library). To run on the simulator there is
a thin iOS **app target** that hosts it, defined by `project.yml` and generated
into `DDPAIDashcam.xcodeproj` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
The generated project is committed, so on a Mac with Xcode you can just:

```sh
open DDPAIDashcam.xcodeproj
```

Then pick an **iPhone simulator** destination and press **Run (⌘R)**. The app
target is `DDPAIDashcam` and its entry point is `App/DashcamHostApp.swift`, which
boots the package's `DependencyContainer` and shows the `RootView` tab shell.

### Regenerating the project

If you change `project.yml` (or add files under `App/`), regenerate with:

```sh
brew install xcodegen   # once
xcodegen generate
```

## Technology stack

- Swift 5.9+ (requires Xcode 15 or newer)
- SwiftUI, MVVM + unidirectional state
- Swift Concurrency (async/await, actors, `AsyncStream`)
- `URLSession` (HTTP, ranged GET), `AVFoundation` (live/clip playback),
  `NWPathMonitor` (reachability)
- Persistence: SQLite via [GRDB](https://github.com/groue/GRDB.swift) (`7.11.1`)
- Property-based testing: [SwiftCheck](https://github.com/typelift/SwiftCheck) (`0.12.0`)

## Project layout

```
Package.swift            Swift package manifest (the DDPAIDashcam library)
project.yml              XcodeGen spec for the iOS app target
DDPAIDashcam.xcodeproj   generated Xcode project (open this to run)
App/
  DashcamHostApp.swift   iOS app @main entry point (hosts the library UI)
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

## Building and testing from the command line

```sh
swift build          # builds the DDPAIDashcam library + GRDB
swift test           # runs the XCTest + SwiftCheck test targets (needs full Xcode)
```

`swift build` works with the Command Line Tools alone. `swift test` and the
SwiftCheck target require a full Xcode installation (for `XCTest`); select it
with `sudo xcode-select -s /Applications/Xcode.app`.
