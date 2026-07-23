import Foundation

/// scrcpy プロセスの起動・監視・終了。
///
/// 表示用とカメラ用の 2 本を常時動かし、録画中だけ音声用の 3 本目を足す。
/// ウィンドウはタイトルで特定するので、キャプチャ用の専用タイトルを付けて起動する。
@MainActor
final class ScrcpyController: ObservableObject {
    enum Kind {
        case display
        case camera

        var title: String {
            switch self {
            case .display: return Config.displayTitle
            case .camera: return Config.cameraTitle
            }
        }

        var geometry: WindowGeometry {
            switch self {
            case .display: return Config.displayWindow
            case .camera: return Config.cameraWindow
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// scrcpy を再起動したときに呼ばれる。再起動後のウィンドウは windowID が変わるので、
    /// キャプチャ側は必ずウィンドウを見つけ直して繋ぎ直す必要がある。
    var onRelaunch: ((Kind) -> Void)?

    private var processes: [Kind: Process] = [:]
    private var restartCounts: [Kind: Int] = [:]
    private var stopping = false

    /// scrcpy が予期せず落ちたときの再起動上限。
    /// このマシンでは Unity 同梱 adb と platform-tools adb が adb サーバを奪い合い、
    /// その巻き添えで scrcpy が起動失敗/切断することがあるため自動復帰させる。
    private let maxRestarts = 5

    func start() {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: Config.scrcpyPath) else {
            lastError = "scrcpy not found at \(Config.scrcpyPath)"
            return
        }
        guard !Config.serial.isEmpty else {
            lastError = "No glasses found. Connect them over adb, or set the serial with "
                + "defaults write com.hacha.rokidliveview serial -string <serial>"
            return
        }
        stopping = false
        lastError = nil
        restartCounts = [:]
        isRunning = true
        launch(.display)
        launch(.camera)
    }

    func stop() {
        stopping = true
        isRunning = false
        for process in processes.values where process.isRunning {
            // scrcpy は SIGTERM で録画を確定して正常終了する
            process.terminate()
        }
        processes.removeAll()
    }

    private func launch(_ kind: Kind) {
        let geometry = kind.geometry
        var arguments = [
            "-s", Config.serial,
            "--no-audio",
            "--no-control",
            "--window-title=\(kind.title)",
            "--window-borderless",
            "--window-x=\(geometry.x)",
            "--window-y=\(geometry.y)",
            "--window-width=\(geometry.width)",
            "--window-height=\(geometry.height)",
        ]
        if kind == .camera {
            arguments += ["--video-source=camera", "--orientation=\(Config.cameraOrientation)"]
        }

        let process = makeProcess(arguments: arguments)
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(kind, status: finished.terminationStatus) }
        }
        do {
            try process.run()
            processes[kind] = process
        } catch {
            lastError = "Failed to launch scrcpy: \(error.localizedDescription)"
            isRunning = false
        }
    }

    private func handleTermination(_ kind: Kind, status: Int32) {
        guard !stopping, isRunning else { return }
        let count = (restartCounts[kind] ?? 0) + 1
        restartCounts[kind] = count
        guard count <= maxRestarts else {
            lastError = "scrcpy (\(kind.title)) keeps exiting. Check the state of adb."
            isRunning = false
            return
        }
        lastError = "scrcpy (\(kind.title)) exited (status \(status)). Restarting (\(count)/\(maxRestarts))"
        // adb サーバの奪い合いは数秒で収まることが多いので、少し待ってから再試行する
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning, !self.stopping else { return }
            self.launch(kind)
            guard self.processes[kind] != nil else { return }
            self.onRelaunch?(kind)
        }
    }

    /// 録画用の音声だけを取る scrcpy。映像もウィンドウも持たない。
    static func startAudioRecorder(to url: URL) -> Process? {
        let arguments = [
            "-s", Config.serial,
            "--no-video",
            "--no-control",
            "--audio-source=mic",
            // scrcpy の既定は opus。mp4 に入れると QuickTime で再生できないので aac にする
            "--audio-codec=aac",
            "--record=\(url.path)",
        ]
        let process = makeProcessStatic(arguments: arguments)
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    private func makeProcess(arguments: [String]) -> Process {
        Self.makeProcessStatic(arguments: arguments)
    }

    private static func makeProcessStatic(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.scrcpyPath)
        process.arguments = arguments

        // Finder から起動した .app の PATH には Homebrew も platform-tools も入らないので明示注入する。
        // ADB を固定しないと Unity 同梱の adb を掴んでサーバを奪い合うことがある。
        var environment = ProcessInfo.processInfo.environment
        let adbDirectory = (Config.adbPath as NSString).deletingLastPathComponent
        environment["PATH"] = "\(adbDirectory):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["ADB"] = Config.adbPath
        process.environment = environment

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
