// Connection / Live_Preview / Media_Browser views
//
// Task 16.1: `ConnectionView`, `LivePreviewView`, and `MediaBrowserView`,
// each bound to the matching view model from task 15.1.
//
// Design reference: design.md → Architecture (MVVM + unidirectional state) and
// "Connection State as Shared Observable". Views are declarative and thin: they
// render a function of their view-model state and forward user intents. No
// business logic lives here — ordering, filtering, timeouts, stream lifecycle,
// and reconnection all live in the subsystems behind the view models.
//
// SwiftUI is guarded by `#if canImport(SwiftUI)` so the package still compiles
// on the macOS command-line toolchain used for `swift build`.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - ConnectionView (R1.1, R1.3, R1.4)

/// Connection screen. Shows the link status label (R1.1), the connected camera
/// model (R1.3), the latest status/instruction message including the
/// join-hotspot instruction (R1.4), and connect / disconnect controls.
public struct ConnectionView: View {

    @ObservedObject private var viewModel: ConnectionViewModel

    public init(viewModel: ConnectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // R1.1: current link status label.
            HStack {
                Text("Status")
                    .font(.headline)
                Spacer()
                Text(viewModel.statusLabel)
                    .foregroundStyle(.secondary)
            }

            // R1.3: the connected camera model, shown only once connected.
            if viewModel.isConnected, let model = viewModel.cameraModel {
                HStack {
                    Text("Camera")
                        .font(.headline)
                    Spacer()
                    Text(model)
                        .foregroundStyle(.secondary)
                }
            }

            // R1.4–R1.9: latest instruction / failure message (join hotspot,
            // connect failure, reconnection prompt, link-lost).
            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Connect / disconnect controls.
            if viewModel.isConnected {
                Button("Disconnect") {
                    Task { await viewModel.disconnect() }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Connect") {
                    Task { await viewModel.connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.state == .connecting)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Camera")
    }
}

// MARK: - LivePreviewView (R2.3, R2.5, R2.6, R2.7)

/// Live preview screen. Shows a video-surface placeholder while rendering with
/// the resolution + signal indicators (R2.3), a mute toggle only when audio is
/// available (R2.6), and a stream-unavailable message with retry when retry is
/// offered (R2.7). Opens the stream on appear and closes it on disappear (R2.5).
public struct LivePreviewView: View {

    @ObservedObject private var viewModel: LivePreviewViewModel

    public init(viewModel: LivePreviewViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            videoSurface

            // R2.6: mute control appears only when the camera reports audio.
            if viewModel.audioAvailable {
                Toggle(isOn: muteBinding) {
                    Label("Mute audio", systemImage: viewModel.isAudioMuted ? "speaker.slash" : "speaker.wave.2")
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .navigationTitle("Live")
        // R2.5: open on appear, tear down on leaving the screen.
        .task { await viewModel.open() }
        .onDisappear { Task { await viewModel.close() } }
    }

    /// The video surface: a placeholder rectangle while rendering, overlaid with
    /// the resolution + signal indicators (R2.3); or the unavailable message
    /// with a retry control (R2.7); or a neutral starting placeholder.
    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

            if viewModel.isRendering {
                // R2.3: resolution + signal indicators while rendering.
                VStack {
                    HStack {
                        if let resolution = viewModel.resolutionLabel {
                            indicatorChip(resolution, systemImage: "rectangle.on.rectangle")
                        }
                        Spacer()
                        if let signal = viewModel.signal {
                            indicatorChip(signalLabel(signal), systemImage: "wifi")
                        }
                    }
                    .padding(8)
                    Spacer()
                }
            } else if let message = viewModel.unavailableMessage {
                // R2.7: stream unavailable + retry.
                VStack(spacing: 12) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if viewModel.canRetry {
                        Button("Retry") {
                            Task { await viewModel.retry() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                // Starting / idle: a neutral placeholder.
                ProgressView()
                    .tint(.white)
            }
        }
        .padding(.horizontal)
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isAudioMuted },
            set: { viewModel.setMuted($0) }
        )
    }

    private func indicatorChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func signalLabel(_ signal: SignalQuality) -> String {
        switch signal {
        case .poor: return "Poor"
        case .fair: return "Fair"
        case .good: return "Good"
        }
    }
}

// MARK: - MediaBrowserView (R3.2, R3.3, R3.4, R3.5, R3.6, R3.8, R6.1)

/// Media browser screen. Lists the clip rows with duration / size text and the
/// type + protected indicators (R3.3, R3.4, R6.1), a filter control
/// (all / normal / event / emergency) (R3.5, R3.6), a loading indicator (R3.2),
/// and empty / error states with retry (R3.8).
public struct MediaBrowserView: View {

    @ObservedObject private var viewModel: MediaBrowserViewModel

    public init(viewModel: MediaBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // R3.5, R3.6: clip-type filter control.
            Picker("Filter", selection: filterBinding) {
                Text("All").tag(ClipFilter.all)
                Text("Normal").tag(ClipFilter.normal)
                Text("Event").tag(ClipFilter.event)
                Text("Emergency").tag(ClipFilter.emergency)
            }
            .pickerStyle(.segmented)
            .padding()

            content
        }
        .navigationTitle("Recordings")
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            // R3.2: loading indicator during retrieval.
            Spacer()
            ProgressView("Loading recordings…")
            Spacer()
        } else if let message = viewModel.emptyMessage {
            // R3.6, R3.8, R6.3: empty-library / no-matching / no-emergency.
            Spacer()
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        } else if let message = viewModel.errorMessage {
            // R3.9, R3.10: failure / connection-lost with retry.
            Spacer()
            VStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if viewModel.canRetry {
                    Button("Retry") { Task { await viewModel.retry() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            Spacer()
        } else {
            List(viewModel.rows) { row in
                ClipRowView(row: row)
            }
            .listStyle(.plain)
        }
    }

    private var filterBinding: Binding<ClipFilter> {
        Binding(
            get: { viewModel.filter },
            set: { viewModel.setFilter($0) }
        )
    }
}

/// A single clip row: timestamp, duration + size text (R3.3), the type marker
/// (R3.4), the protected marker (R6.1), and a downloaded indicator.
struct ClipRowView: View {

    let row: ClipRowViewData

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.startTimestamp, style: .date)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(row.durationText)
                    Text("·")
                    Text(row.sizeText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // R3.4: event vs normal type indicator.
            if row.typeMarker == .event {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Event clip")
            }

            // R6.1: protected (emergency footage) indicator.
            if row.protectionMarker == .protected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Protected clip")
            }

            // Downloaded (in Local_Library) indicator.
            if row.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        }
        .padding(.vertical, 4)
    }
}

#endif
