// Root navigation shell
//
// Task 16.3: `RootView` is the TabView navigation shell that connects every
// feature screen, each built from the shared `DependencyContainer` so they all
// observe the one `ConnectionManager` / shared `Connection_State` (R1.1, R7.1).
//
// SwiftUI is guarded by `#if canImport(SwiftUI)` so the package still builds on
// the macOS command-line toolchain used for `swift build`.

#if canImport(SwiftUI)
import SwiftUI

/// The app's navigation shell: a tab per feature area. View models are created
/// once from the container and held for the lifetime of the shell so each
/// screen observes the single shared Connection_State (R1.1).
public struct RootView: View {

    private let container: DependencyContainer

    @StateObject private var connectionViewModel: ConnectionViewModel
    @StateObject private var livePreviewViewModel: LivePreviewViewModel
    @StateObject private var mediaBrowserViewModel: MediaBrowserViewModel
    @StateObject private var downloadViewModel: DownloadViewModel
    @StateObject private var localLibraryViewModel: LocalLibraryViewModel
    @StateObject private var settingsViewModel: SettingsViewModel

    public init(container: DependencyContainer) {
        self.container = container
        _connectionViewModel = StateObject(wrappedValue: container.makeConnectionViewModel())
        _livePreviewViewModel = StateObject(wrappedValue: container.makeLivePreviewViewModel())
        _mediaBrowserViewModel = StateObject(wrappedValue: container.makeMediaBrowserViewModel())
        _downloadViewModel = StateObject(wrappedValue: container.makeDownloadViewModel())
        _localLibraryViewModel = StateObject(wrappedValue: container.makeLocalLibraryViewModel())
        _settingsViewModel = StateObject(wrappedValue: container.makeSettingsViewModel())
    }

    public var body: some View {
        TabView {
            NavigationStack {
                ConnectionView(viewModel: connectionViewModel)
            }
            .tabItem { Label("Camera", systemImage: "car.fill") }

            NavigationStack {
                LivePreviewView(viewModel: livePreviewViewModel)
            }
            .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }

            NavigationStack {
                MediaBrowserView(viewModel: mediaBrowserViewModel)
            }
            .tabItem { Label("Recordings", systemImage: "film.stack") }

            NavigationStack {
                DownloadQueueView(viewModel: downloadViewModel)
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack {
                LocalLibraryView(viewModel: localLibraryViewModel)
            }
            .tabItem { Label("Library", systemImage: "square.stack") }

            NavigationStack {
                SettingsView(viewModel: settingsViewModel)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }

    /// A convenience factory for the media player view model, so a browser /
    /// library selection can push a `MediaPlayerView` for a specific clip.
    public func makeMediaPlayerViewModel() -> MediaPlayerViewModel {
        container.makeMediaPlayerViewModel()
    }
}

#endif
