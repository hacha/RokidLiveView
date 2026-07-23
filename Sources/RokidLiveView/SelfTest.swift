import AppKit
import CoreImage
import Foundation

/// `--selftest` 付きで起動したときの自動スモークテスト。
///
/// 開始 → ウィンドウ検出 → 合成 → 静止画保存 → 数秒録画 → 終了、までを人手なしで通す。
/// 出力を見れば合成結果と録画が壊れていないか確認できる。
@MainActor
enum SelfTest {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run(engine: LiveEngine) {
        Task {
            let report = Report()
            report.log("=== selftest 開始 ===")

            engine.start()
            guard await waitUntil(timeout: 40, condition: { engine.isRunning }) else {
                report.log("FAIL: 稼働状態にならなかった (\(engine.state.message))")
                report.finish()
                NSApp.terminate(nil)
                return
            }
            report.log("OK: 稼働中まで到達")

            // 最初のフレームが両ソースから届くのを待つ
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            guard let image = engine.currentImage() else {
                report.log("FAIL: 合成画像が得られない")
                report.finish()
                NSApp.terminate(nil)
                return
            }
            report.log("OK: 合成サイズ \(Int(image.extent.width))x\(Int(image.extent.height))")

            let still = (try? Config.ensureOutputDirectory())?
                .appendingPathComponent("selftest-\(stamp()).png") ?? Config.outputDirectory
            do {
                try engine.compositor.ciContext.writePNGRepresentation(
                    of: image, to: still, format: .RGBA8, colorSpace: engine.compositor.colorSpace)
                report.log("OK: 静止画 \(still.path)")
            } catch {
                report.log("FAIL: 静止画を保存できない: \(error.localizedDescription)")
            }

            engine.toggleRecording()
            guard engine.recorder.isRecording else {
                report.log("FAIL: 録画を開始できない (\(engine.recorder.lastError ?? "理由不明"))")
                report.finish()
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            engine.toggleRecording()
            report.log("OK: 6秒録画して停止")

            _ = await waitUntil(timeout: 30, condition: { engine.recorder.lastOutput != nil })
            if let output = engine.recorder.lastOutput {
                report.log("OK: 録画ファイル \(output.path)")
            } else {
                report.log("FAIL: 録画ファイルが確定しなかった")
            }
            if let error = engine.recorder.lastError { report.log("NOTE: \(error)") }

            await checkRestartRecovery(engine: engine, report: report)

            if let error = engine.scrcpy.lastError { report.log("NOTE: scrcpy \(error)") }
            engine.stop()
            report.log("=== selftest 完了 ===")
            report.finish()
            NSApp.terminate(nil)
        }
    }

    /// scrcpy を外から落として、自動再起動とキャプチャの繋ぎ直しが効くかを確かめる。
    ///
    /// 再起動後のウィンドウは windowID が変わるので、scrcpy を上げ直すだけでは映像が
    /// 最後のフレームで固まる。繋ぎ直しが効いていれば、フレーム数が 0 にリセットされてから再び増える。
    private static func checkRestartRecovery(engine: LiveEngine, report: Report) async {
        let before = engine.cameraFrameCount
        guard before > 0 else {
            report.log("SKIP: カメラのフレームが来ていないので再起動テストを省略")
            return
        }
        report.log("--- scrcpy 強制終了からの復帰を確認 (kill 前 \(before) フレーム) ---")

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "window-title=\(Config.cameraTitle)"]
        try? kill.run()
        kill.waitUntilExit()

        // 繋ぎ直しでカウンタが 0 に戻り、そのあと再び増えれば復帰成功
        guard await waitUntil(timeout: 30, condition: { engine.cameraFrameCount < before }) else {
            report.log("FAIL: 繋ぎ直しが走らなかった (フレーム数がリセットされない)")
            return
        }
        guard await waitUntil(timeout: 40, condition: { engine.cameraFrameCount > 30 }) else {
            report.log("FAIL: 再起動後にフレームが再開しない (\(engine.cameraFrameCount) フレーム)")
            return
        }
        report.log("OK: 自動再起動と繋ぎ直しで映像が再開 (\(engine.cameraFrameCount) フレーム)")
    }

    private static func waitUntil(timeout: TimeInterval, condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return condition()
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 結果はログファイルに書く (.app は標準出力が端末に出ないため)
    final class Report {
        private let url = Config.outputDirectory.appendingPathComponent("selftest.log")
        private var lines: [String] = []

        func log(_ message: String) {
            lines.append(message)
            NSLog("RokidLiveView selftest: \(message)")
        }

        func finish() {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
