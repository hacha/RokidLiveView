import AppKit
import CoreImage
import CoreMedia
import Foundation
import Metal
import ScreenCaptureKit

/// scrcpy 起動 → ウィンドウ検出 → キャプチャ開始 → 合成、までの全体を束ねる。
@MainActor
final class LiveEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case launchingScrcpy
        case waitingForWindows
        case running
        case failed(String)

        var message: String {
            switch self {
            case .idle: return "Stopped"
            case .launchingScrcpy: return "Launching scrcpy…"
            case .waitingForWindows: return "Waiting for the scrcpy windows…"
            case .running: return "Running"
            case .failed(let reason): return "Error: \(reason)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var needsScreenRecordingPermission = false

    let scrcpy = ScrcpyController()
    let recorder = Recorder()
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let compositor: Compositor

    private let cameraSource = CaptureSource(name: "camera")
    private let displaySource = CaptureSource(name: "display")
    private var startTask: Task<Void, Never>?
    private var rebindTask: Task<Void, Never>?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.compositor = Compositor(mtlCommandQueue: queue)
    }

    var isRunning: Bool { state == .running }

    /// カメラ側が受け取った画素付きフレーム数。繋ぎ直しのたびに 0 に戻る (スモークテスト用)
    var cameraFrameCount: Int { cameraSource.receivedFrames }

    /// 合成結果。プレビューと録画の両方がこれを使う。
    func currentImage() -> CIImage? {
        compositor.compose(camera: cameraSource.latestFrame, hud: displaySource.latestFrame)
    }

    func start() {
        guard state == .idle || isFailed else { return }

        guard WindowFinder.ensureScreenRecordingPermission() else {
            needsScreenRecordingPermission = true
            state = .failed("Screen Recording permission is not granted")
            return
        }
        needsScreenRecordingPermission = false

        state = .launchingScrcpy
        // scrcpy が落ちて再起動されると windowID が変わるので、そのソースだけ繋ぎ直す
        scrcpy.onRelaunch = { [weak self] kind in
            self?.rebind(kind)
        }
        scrcpy.start()
        if let error = scrcpy.lastError, !scrcpy.isRunning {
            state = .failed(error)
            return
        }

        startTask = Task { [weak self] in
            guard let self else { return }
            self.state = .waitingForWindows

            async let camera = WindowFinder.find(titled: Config.cameraTitle)
            async let display = WindowFinder.find(titled: Config.displayTitle)
            let (cameraWindow, displayWindow) = await (camera, display)

            guard !Task.isCancelled else { return }
            guard let cameraWindow else {
                self.state = .failed("Could not find the camera scrcpy window")
                return
            }
            guard let displayWindow else {
                self.state = .failed("Could not find the display scrcpy window")
                return
            }

            do {
                try self.cameraSource.start(
                    window: cameraWindow, scale: WindowFinder.backingScale(for: cameraWindow))
                try self.displaySource.start(
                    window: displayWindow, scale: WindowFinder.backingScale(for: displayWindow))
            } catch {
                self.state = .failed("Cannot start capture: \(error.localizedDescription)")
                return
            }
            self.state = .running
        }
    }

    /// 再起動された scrcpy のウィンドウを探し直し、そのソースだけキャプチャを張り直す。
    /// これをやらないと古い windowID に紐づいた SCStream が死んだまま残り、
    /// 映像が最後のフレームで固まってしまう。
    private func rebind(_ kind: ScrcpyController.Kind) {
        let source = kind == .camera ? cameraSource : displaySource
        let title = kind.title
        source.stop()
        rebindTask?.cancel()
        rebindTask = Task { [weak self] in
            guard let self else { return }
            guard let window = await WindowFinder.find(titled: title) else {
                self.state = .failed("Could not re-acquire the scrcpy window for \(title)")
                return
            }
            guard !Task.isCancelled, self.scrcpy.isRunning else { return }
            do {
                try source.start(window: window, scale: WindowFinder.backingScale(for: window))
            } catch {
                self.state = .failed("Cannot re-attach capture: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        rebindTask?.cancel()
        rebindTask = nil
        scrcpy.onRelaunch = nil
        if recorder.isRecording { recorder.stop() }
        cameraSource.stop()
        displaySource.stop()
        scrcpy.stop()
        state = .idle
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            guard let image = currentImage() else { return }
            recorder.start(size: image.extent.size)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
