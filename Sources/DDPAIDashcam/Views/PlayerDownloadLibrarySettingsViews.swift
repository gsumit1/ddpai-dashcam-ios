// Media_Player / Download_Manager / Local_Library / Settings_Controller views
//
// Task 16.2: `MediaPlayerView`, `DownloadQueueView`, `LocalLibraryView`, and
// the `SettingsView` family, each bound to the matching view model from task
// 15.2.
//
// Design reference: design.md → Architecture (MVVM + unidirectional state).
// Views are declarative and thin: seek clamping, queue ordering, resume gating,
// storage checks, delete semantics, and the optimistic-with-revert settings
// write pattern all live in the subsystems. The views only render state and
// forward intents.
//
// SwiftUI is guarded by `#if canImport(SwiftUI)` so the package still compiles
// on the macOS command-line toolchain used for `swift build`. Photos export is
// further guarded by `#if canImport(Photos)`.

#if canImport(SwiftUI)
import SwiftUI

#if canImport(Photos)
import Photos
#endif

// MARK: - MediaPlayerView (R4.2, R4.3)

/// Playback screen. Provides play / pause and a seek scrubber bound to the
/// position / duration (R4.2), and shows position / duration text (R4.3). The
/// subsystem clamps the seek to `0...duration`; this view forwards the position.
public struct MediaPlayerView: View {

    @ObservedObject private var viewModel: MediaPlayerViewModel
    private let clip: ClipID

    /// Local scrubbing position in seconds, used while the user drags.
    @State private var scrubSeconds: Double = 0
    @State private var isScrubbing = false

    public init(viewModel: MediaPlayerViewModel, clip: ClipID) {
        self.viewModel = viewModel
        self.clip = clip
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if let message = viewModel.unavailableMessage {
                // R4.7: clip neither local nor streamable.
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let message = viewModel.failureMessage {
                // R4.4, R4.5: playback failed, offer retry.
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
            }

            // R4.3: position / duration readouts.
            HStack {
                Text(viewModel.positionText)
                Spacer()
                Text(viewModel.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal)

            // R4.2: seek scrubber.
            Slider(
                value: seekBinding,
                in: 0...max(durationSeconds, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        viewModel.seek(to: .seconds(scrubSeconds))
                    }
                }
            )
            .padding(.horizontal)
            .disabled(durationSeconds <= 0)

            // R4.1, R4.2: play / pause.
            Button {
                if viewModel.isPlaying {
                    viewModel.pause()
                } else {
                    Task { await viewModel.play(clip) }
                }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }

            Spacer()
        }
        .navigationTitle("Playback")
        .task { await viewModel.play(clip) }
    }

    private var durationSeconds: Double {
        Double(viewModel.duration.components.seconds)
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: {
                if isScrubbing { return scrubSeconds }
                return Double(viewModel.position.components.seconds)
            },
            set: { scrubSeconds = $0 }
        )
    }
}

// MARK: - DownloadQueueView (R5.2, R5.5, R5.7, R5.8)

/// Download queue screen. Lists each queued / active download with its integer
/// progress percent (R5.2), and surfaces interrupted + resume affordances per
/// task (R5.5, R5.7) and an insufficient-storage message (R5.8).
public struct DownloadQueueView: View {

    @ObservedObject private var viewModel: DownloadViewModel

    public init(viewModel: DownloadViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                VStack {
                    Spacer()
                    Text("No downloads in progress.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(viewModel.rows) { row in
                    DownloadRowView(
                        row: row,
                        onResume: { Task { await viewModel.resume(row.clipID) } },
                        onCancel: { Task { await viewModel.cancel(row.clipID) } }
                    )
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Downloads")
        .overlay(alignment: .bottom) {
            if let message = viewModel.message {
                Text(message)
                    .font(.caption)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .onAppear { viewModel.startObserving() }
        .onDisappear { viewModel.stopObserving() }
    }
}

/// A single download row: clip id, size, a progress bar with the integer
/// percent (R5.2), and status-dependent controls — resume when interrupted
/// (R5.5, R5.7), an insufficient-storage message (R5.8), and cancel otherwise.
struct DownloadRowView: View {

    let row: DownloadRowViewData
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.clipID)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(row.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // R5.2: progress bar with integer percent.
            ProgressView(value: Double(row.percent), total: 100) {
                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(row.percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // R5.8: insufficient-storage message.
            if let message = row.insufficientStorageMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // R5.5, R5.7: resume affordance when interrupted; else cancel.
            HStack {
                Spacer()
                if row.isInterrupted {
                    Button("Resume", action: onResume)
                        .buttonStyle(.bordered)
                } else if canCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var canCancel: Bool {
        switch row.status {
        case .queued, .inProgress: return true
        case .interrupted, .completed, .canceled, .failedInsufficientStorage: return false
        }
    }

    private var statusText: String {
        switch row.status {
        case .queued: return "Queued"
        case .inProgress: return "Downloading"
        case .interrupted: return "Interrupted"
        case .completed: return "Completed"
        case .canceled: return "Canceled"
        case .failedInsufficientStorage: return "Not enough storage"
        }
    }
}

// MARK: - LocalLibraryView (R7.3, R7.6, R7.7, R7.8)

/// Local library screen. Lists downloaded clips (available offline — R7.1),
/// shows an empty-state message (R7.3), offers a share sheet via `ShareLink`
/// (R7.6), and exports a clip to the photo library with permission handling
/// (R7.7 granted, R7.8 denied).
public struct LocalLibraryView: View {

    @ObservedObject private var viewModel: LocalLibraryViewModel

    @State private var exportMessage: String?

    public init(viewModel: LocalLibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.isEmpty {
                // R7.3: empty-state message.
                VStack {
                    Spacer()
                    Text(LocalLibraryMessage.empty)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.clips) { clip in
                        LocalClipRowView(
                            clip: clip,
                            onExport: { export(clip) }
                        )
                    }
                    .onDelete(perform: deleteRows)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .task { await viewModel.load() }
        .overlay(alignment: .bottom) { statusBanner }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = exportMessage ?? viewModel.message {
            Text(message)
                .font(.caption)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }

    private func deleteRows(_ offsets: IndexSet) {
        let ids = offsets.map { viewModel.clips[$0].clipID }
        Task {
            for id in ids { await viewModel.delete(id) }
        }
    }

    /// R7.7 / R7.8: export a clip to the photo library, requesting authorization
    /// and surfacing a denied message when permission is refused.
    private func export(_ clip: StoredClipViewData) {
        #if canImport(Photos)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip.fileURL)
                } completionHandler: { success, _ in
                    Task { @MainActor in
                        exportMessage = success
                            ? "Saved to your photo library."
                            : "Could not save the clip to your photo library."
                    }
                }
            case .denied, .restricted, .notDetermined:
                // R7.8: permission denied — surface a message.
                Task { @MainActor in
                    exportMessage = "Photo library access is required to save clips. Enable it in Settings."
                }
            @unknown default:
                Task { @MainActor in
                    exportMessage = "Could not save the clip to your photo library."
                }
            }
        }
        #else
        exportMessage = "Photo library export is unavailable on this platform."
        #endif
    }
}

/// A single stored-clip row: timestamp, duration + size text, a protected
/// indicator, a share sheet (R7.6), and a photo-library export action (R7.7).
struct LocalClipRowView: View {

    let clip: StoredClipViewData
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.startTimestamp, style: .date)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(clip.durationText)
                    Text("·")
                    Text(clip.sizeText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if clip.protectionMarker == .protected {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Protected clip")
            }

            // R7.6: share sheet for the on-device file.
            ShareLink(item: clip.fileURL) {
                Image(systemName: "square.and.arrow.up")
            }

            // R7.7: export to the photo library.
            Button(action: onExport) {
                Image(systemName: "photo.on.rectangle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Save to photos")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SettingsView (R8.1, R8.5, R8.6, R9.2, R10.1, R11.1, R11.4, R11.7)

/// Settings screen. Renders resolution, collision sensitivity, audio toggle,
/// and parking mode / sensitivity controls, each reflecting the subsystem's
/// per-setting state: enabled only while connected (R8.5, R11.7), disabled with
/// an in-progress indicator while a write is pending (R8.6, R9.2), and surfacing
/// the retrieved current value / options (R8.1, R10.1, R11.1, R11.4).
public struct SettingsView: View {

    @ObservedObject private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            if viewModel.isSyncing {
                // R12.1: sync in progress.
                Section { ProgressView("Loading settings…") }
            } else if viewModel.isUnavailable {
                // R12.2: settings unavailable after exhausting retries, retry.
                Section {
                    if let message = viewModel.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button("Retry") { Task { await viewModel.syncAll() } }
                }
            } else {
                recordingSection
                collisionSection
                parkingSection
            }
        }
        .navigationTitle("Settings")
        .task { await viewModel.syncAll() }
    }

    // R8.1: resolution + R10.1: audio recording toggle.
    @ViewBuilder
    private var recordingSection: some View {
        Section("Recording") {
            resolutionPicker
            audioToggle
        }
    }

    @ViewBuilder
    private var resolutionPicker: some View {
        if let state = viewModel.state(for: .resolution) {
            let options = resolutionOptions(state.options)
            Picker("Resolution", selection: resolutionBinding(current: state.currentValue)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .disabled(!viewModel.isEnabled(.resolution))
            .overlay(alignment: .trailing) { pendingIndicator(.resolution) }
        }
    }

    @ViewBuilder
    private var audioToggle: some View {
        if viewModel.state(for: .audioRecording) != nil {
            Toggle("Record audio", isOn: audioBinding)
                .disabled(!viewModel.isEnabled(.audioRecording))
                .overlay(alignment: .trailing) { pendingIndicator(.audioRecording) }
        }
    }

    // R9.2: collision sensitivity with in-progress indicator.
    @ViewBuilder
    private var collisionSection: some View {
        if let state = viewModel.state(for: .collisionSensitivity) {
            Section("Collision") {
                let levels = levelOptions(state.options)
                Picker("Sensitivity", selection: levelBinding(.collisionSensitivity, current: state.currentValue)) {
                    ForEach(levels, id: \.self) { level in
                        Text("Level \(level)").tag(level)
                    }
                }
                .disabled(!viewModel.isEnabled(.collisionSensitivity))
                .overlay(alignment: .trailing) { pendingIndicator(.collisionSensitivity) }
            }
        }
    }

    // R11.1, R11.4, R11.7: parking mode + sensitivity.
    @ViewBuilder
    private var parkingSection: some View {
        Section("Parking") {
            if let state = viewModel.state(for: .parkingMode) {
                let options = parkingModeOptions(state.options)
                Picker("Mode", selection: parkingModeBinding(current: state.currentValue)) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .disabled(!viewModel.isEnabled(.parkingMode))
                .overlay(alignment: .trailing) { pendingIndicator(.parkingMode) }
            }

            // R11.4: sensitivity exposed when the mode provides it.
            if let state = viewModel.state(for: .parkingSensitivity) {
                let levels = levelOptions(state.options)
                Picker("Sensitivity", selection: levelBinding(.parkingSensitivity, current: state.currentValue)) {
                    ForEach(levels, id: \.self) { level in
                        Text("Level \(level)").tag(level)
                    }
                }
                .disabled(!viewModel.isEnabled(.parkingSensitivity))
                .overlay(alignment: .trailing) { pendingIndicator(.parkingSensitivity) }
            }
        }
    }

    // MARK: Pending indicator (R8.6, R9.2)

    @ViewBuilder
    private func pendingIndicator(_ key: SettingKey) -> some View {
        if viewModel.isPending(key) {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: Option extraction helpers

    private func resolutionOptions(_ options: [SettingValue]) -> [String] {
        options.compactMap { if case .resolution(let value) = $0 { return value } else { return nil } }
    }

    private func parkingModeOptions(_ options: [SettingValue]) -> [String] {
        options.compactMap { if case .parkingMode(let value) = $0 { return value } else { return nil } }
    }

    private func levelOptions(_ options: [SettingValue]) -> [Int] {
        options.compactMap { if case .level(let value) = $0 { return value } else { return nil } }
    }

    // MARK: Bindings — forward writes to the subsystem (optimistic-with-revert)

    private func resolutionBinding(current: SettingValue?) -> Binding<String> {
        Binding(
            get: {
                if case .resolution(let value)? = current { return value }
                return ""
            },
            set: { newValue in Task { await viewModel.writeSetting(.resolution, .resolution(newValue)) } }
        )
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value)? = viewModel.state(for: .audioRecording)?.currentValue { return value }
                return false
            },
            set: { _ in Task { await viewModel.toggleAudioRecording() } }
        )
    }

    private func levelBinding(_ key: SettingKey, current: SettingValue?) -> Binding<Int> {
        Binding(
            get: {
                if case .level(let value)? = current { return value }
                return 0
            },
            set: { newValue in Task { await viewModel.writeSetting(key, .level(newValue)) } }
        )
    }

    private func parkingModeBinding(current: SettingValue?) -> Binding<String> {
        Binding(
            get: {
                if case .parkingMode(let value)? = current { return value }
                return ""
            },
            set: { newValue in Task { await viewModel.writeSetting(.parkingMode, .parkingMode(newValue)) } }
        )
    }
}

#endif
