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
                let fullSize = compositor.lastFullFrameSize ?? image.extent.size
                compositor.ciContext.render(
                    fitted(image, into: target, fullFrameSize: fullSize, cropOrigin: compositor.lastCropOrigin),
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

        /// フル (クロップ前) フレームがビューに収まるスケールを基準に描く。
        /// image 自体がクロップ済みで小さくても同じスケールを使うので、
        /// Full/Crop を切り替えても拡大縮小されず、切り取られた位置もそのまま保たれる
        /// (crop で見えなくなった部分は黒帯として残るだけ)。
        private func fitted(
            _ image: CIImage, into target: CGRect, fullFrameSize: CGSize, cropOrigin: CGPoint
        ) -> CIImage {
            guard fullFrameSize.width > 0, fullFrameSize.height > 0 else { return image }
            let scale = min(target.width / fullFrameSize.width, target.height / fullFrameSize.height)

            // フルフレームをビュー中央に置いたときの左下隅の位置
            let fullOriginX = target.midX - fullFrameSize.width * scale / 2
            let fullOriginY = target.midY - fullFrameSize.height * scale / 2

            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = scaled.transformed(by: CGAffineTransform(
                translationX: fullOriginX + cropOrigin.x * scale - scaled.extent.minX,
                y: fullOriginY + cropOrigin.y * scale - scaled.extent.minY
            ))
            return placed.composited(over: CIImage(color: .black).cropped(to: target))
        }
    }
}
