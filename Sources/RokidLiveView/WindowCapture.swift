import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit で scrcpy のウィンドウ 1 枚を取り込み、「最新の 1 フレーム」だけを保持する。
///
/// SCK は内容が変わっていないフレームを status=idle で送ってきて、そのときは画素を載せない
/// (実測: グラス画面が静止すると idle だけが 60fps で流れる)。
/// そのため最後に受け取った画素バッファを保持し続ける必要がある ＝ これが合成側の「最新フレーム勝ち」を支える。
final class CaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let name: String

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var stream: SCStream?
    private var frameCount = 0

    init(name: String) {
        self.name = name
    }

    /// 直近の 1 枚。無ければ nil。
    var latestFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 受信したフレーム総数 (画素付きのみ)。ステータス表示用。
    var receivedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    func start(window: SCWindow, scale: CGFloat) throws {
        let configuration = SCStreamConfiguration()
        // 出力サイズをウィンドウの実ピクセル数に一致させる。ずれると背景色でパディングされる。
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture.\(name)"))
        self.stream = stream
        stream.startCapture { _ in }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock()
        latest = nil
        frameCount = 0
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        // 常に 1 枚だけ保持する。前のフレームはここで解放されるので queueDepth を食い潰さない。
        latest = buffer
        frameCount += 1
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("RokidLiveView: capture stopped (\(name)): \(error)")
    }
}

enum WindowFinder {
    /// タイトルに needle を含むウィンドウを探す。scrcpy はウィンドウが出るまで数秒かかるのでポーリングする。
    static func find(titled needle: String, timeout: TimeInterval = 20) async -> SCWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let hit = content.windows.first(where: { ($0.title ?? "").contains(needle) }) {
                return hit
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// 画面収録の許可状態。未許可ならダイアログを出す。
    /// 許可の反映にはアプリの再起動が必要なので、false のときは案内を出すこと。
    static func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// そのウィンドウが載っているディスプレイの Retina 倍率。
    ///
    /// キャプチャ解像度 = ウィンドウの pt サイズ × これ なので、合成の出力解像度を決める。
    /// NSScreen.main は「キーウィンドウのある画面」なので実行ごとに変わってしまう
    /// (実測: 同じ設定で 1080x1920 と 540x960 が交互に出た)。必ずウィンドウ側から引くこと。
    static func backingScale(for window: SCWindow) -> CGFloat {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return 2 }
        // SCWindow.frame は左上原点 (CoreGraphics)、NSScreen.frame は左下原点なので Y を反転する
        let point = CGPoint(x: window.frame.midX, y: primary.frame.maxY - window.frame.midY)
        for screen in screens where screen.frame.contains(point) {
            return screen.backingScaleFactor
        }
        return primary.backingScaleFactor
    }
}
