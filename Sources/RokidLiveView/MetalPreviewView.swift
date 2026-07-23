import CoreImage
import CoreMedia
import MetalKit
import SwiftUI

/// 合成結果を描くプレビュー。
///
/// SCK から届くフレームを待たずに固定 60fps で回し、毎回「各ソースの最新フレーム」を合成する。
/// 表示が静止していても最後の絵が残るので、映像が止まらない。
struct MetalPreviewView: NSViewRepresentable {
    let engine: LiveEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.device)
        view.delegate = context.coordinator
        view.framebufferOnly = false          // CIContext がテクスチャに直接描くため
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoResizeDrawable = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: LiveEngine

        init(engine: LiveEngine) {
            self.engine = engine
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = engine.commandQueue.makeCommandBuffer() else { return }

            let target = CGRect(origin: .zero, size: view.drawableSize)
            let compositor = engine.compositor

            if let image = MainActor.assumeIsolated({ engine.currentImage() }) {
                // 録画は合成結果をそのまま (プレビューの拡縮を掛ける前に) 記録する
                engine.recorder.append(image: image, using: compositor)
                compositor.ciContext.render(
                    fitted(image, into: target),
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: target,
                    colorSpace: compositor.colorSpace
                )
            } else {
                compositor.ciContext.render(
                    CIImage(color: .black).cropped(to: target),
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: target,
                    colorSpace: compositor.colorSpace
                )
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// アスペクト比を保ってビューに収め、余白は黒で埋める (黒帯の描き残しを防ぐ)
        private func fitted(_ image: CIImage, into target: CGRect) -> CIImage {
            guard image.extent.width > 0, image.extent.height > 0 else { return image }
            let scale = min(target.width / image.extent.width, target.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let offsetX = target.midX - scaled.extent.midX
            let offsetY = target.midY - scaled.extent.midY
            let centered = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            return centered.composited(over: CIImage(color: .black).cropped(to: target))
        }
    }
}
