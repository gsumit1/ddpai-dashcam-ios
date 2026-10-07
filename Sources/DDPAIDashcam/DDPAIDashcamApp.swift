// App entry point
//
// Task 16.3: the `@main` SwiftUI `App` that boots the dependency graph and
// shows the `RootView` navigation shell wired to the shared Connection_State
// (R1.1, R7.1).
//
// Guarded by `#if canImport(SwiftUI) && os(iOS)` so the iOS app shell exists in
// the module while the package still compiles on the macOS command-line
// toolchain used for `swift build` (which has no app entry point).

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// The DDPAI dash cam companion app. On launch it assembles the shared
/// `DependencyContainer` (the one `ConnectionManager` + concrete comm layer +
/// `GRDBLibraryStore` + subsystems + view models) and presents the navigation
/// shell. If persistence cannot be initialized the app shows a fatal-setup
/// message rather than crashing silently.
@main
struct DDPAIDashcamApp: App {

    /// Result of building the dependency graph at launch.
    private enum Bootstrap {
        case ready(DependencyContainer)
        case failed(String)
    }

    private let bootstrap: Bootstrap

    init() {
        do {
            let container = try DependencyContainer()
            bootstrap = .ready(container)
        } catch {
            bootstrap = .failed("The app could not start: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .ready(let container):
                RootView(container: container)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }
}

#endif
