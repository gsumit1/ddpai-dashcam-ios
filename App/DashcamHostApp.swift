// iOS app host entry point
//
// This is the runnable iOS app target's `@main` entry point. The actual
// feature code lives in the `DDPAIDashcam` Swift package (the library); this
// thin host simply boots the package's composition root and shows its root
// navigation shell on an iPhone.
//
// Why a separate host target: a Swift Package produces a library, not an
// installable `.app`. An iOS App target is required to run on the simulator /
// device. This file supplies the single `@main` entry point for that target
// and depends on the `DDPAIDashcam` module for everything else.

import SwiftUI
import DDPAIDashcam

@main
struct DashcamHostApp: App {
    var body: some Scene {
        WindowGroup {
            RootViewHost()
        }
    }
}

/// Builds the package's `DependencyContainer` (the one `ConnectionManager` +
/// concrete comm layer + persistence + subsystems + view models) and shows the
/// `RootView` navigation shell. If persistence cannot be initialized the host
/// shows a setup-failure message rather than crashing.
private struct RootViewHost: View {
    private enum Bootstrap {
        case ready(DependencyContainer)
        case failed(String)
    }

    @State private var bootstrap: Bootstrap = {
        do {
            return .ready(try DependencyContainer())
        } catch {
            return .failed("The app could not start: \(error.localizedDescription)")
        }
    }()

    var body: some View {
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
