import AppKit
import ApplicationServices

/// scrcpy の 2 ウィンドウ（`--window-borderless` でタイトルバーが無く、通常のドラッグでは動かせない）を
/// Option+ドラッグで移動できるようにする。
///
/// ウィンドウの内容は合成用に取り込んでいるだけなので、位置を動かしても SCStream は
/// windowID を掴んだままキャプチャを続ける（座標は無関係）。
@MainActor
final class WindowMover {
    private let scrcpy: ScrcpyController
    private var monitor: Any?
    private var draggingWindow: AXUIElement?
    private var dragOffset: CGPoint = .zero

    init(scrcpy: ScrcpyController) {
        self.scrcpy = scrcpy
    }

    func start() {
        guard monitor == nil else { return }
        _ = ensureAccessibilityPermission()
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        draggingWindow = nil
    }

    /// 未許可ならシステム設定への案内ダイアログを出す。許可の反映にはアプリの再起動が要る。
    @discardableResult
    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard event.modifierFlags.contains(.option),
                  let (window, origin) = windowUnderCursor() else { return }
            draggingWindow = window
            let cursor = flippedMouseLocation()
            dragOffset = CGPoint(x: cursor.x - origin.x, y: cursor.y - origin.y)
        case .leftMouseDragged:
            guard let window = draggingWindow else { return }
            let cursor = flippedMouseLocation()
            var newOrigin = CGPoint(x: cursor.x - dragOffset.x, y: cursor.y - dragOffset.y)
            if let value = AXValueCreate(.cgPoint, &newOrigin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        case .leftMouseUp:
            draggingWindow = nil
        default:
            break
        }
    }

    /// NSEvent.mouseLocation はメイン画面（メニューバーのある画面）左下原点なので、
    /// AX/CG の左上原点に合わせる。マルチディスプレイでは全画面の maxY ではなく
    /// メイン画面 (screens.first) の高さを基準にする (WindowFinder.backingScale と同じ考え方)。
    private func flippedMouseLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let maxY = NSScreen.screens.first?.frame.maxY ?? location.y
        return CGPoint(x: location.x, y: maxY - location.y)
    }

    private func windowUnderCursor() -> (AXUIElement, CGPoint)? {
        let cursor = flippedMouseLocation()
        for kind in [ScrcpyController.Kind.display, .camera] {
            guard let pid = scrcpy.processIdentifier(for: kind) else { continue }
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                guard let frame = frame(of: window), frame.contains(cursor) else { continue }
                return (window, frame.origin)
            }
        }
        return nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
