import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal

/// カメラ映像の上にグラス表示を「黒＝素通し」で重ねる合成。
///
/// ffmpeg でオフライン合成する場合の -filter_complex と等価:
///   [hud] hue=s=0, colorchannelmixer=rr:gg:bb, scale=-2:HUD_H, pad=W:H:中央+DX:中央+DY:black
///   [cam][hud] blend=all_mode=screen
///
/// 色管理は切ってある (workingColorSpace = NSNull)。CoreImage は既定でリニア空間に変換してから
/// 合成するため、そのままだとガンマ空間で screen 合成する ffmpeg と絵が変わるため。
final class Compositor {
    let ciContext: CIContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let tint: (r: Double, g: Double, b: Double)?
    private let gain: Double
    private let density: Double

    init(mtlCommandQueue: MTLCommandQueue) {
        ciContext = CIContext(mtlCommandQueue: mtlCommandQueue, options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        tint = Config.hudTintComponents
        gain = Config.hudGain
        density = min(max(Config.hudDensity, 0), 1)
    }

    /// カメラ側の解像度が出力解像度になる。カメラがまだ来ていなければ HUD 単体を返す。
    func compose(camera: CVPixelBuffer?, hud: CVPixelBuffer?) -> CIImage? {
        let cameraImage = camera.map { CIImage(cvPixelBuffer: $0) }
        let hudImage = hud.map { CIImage(cvPixelBuffer: $0) }

        guard let cameraImage else { return hudImage }
        guard let hudImage else { return cameraImage }

        let output = cameraImage.extent
        let padded = layout(hud: styled(hudImage), in: output)

        let blend = CIFilter.screenBlendMode()
        blend.inputImage = padded
        blend.backgroundImage = dimmed(cameraImage, under: padded)
        return blend.outputImage?.cropped(to: output) ?? cameraImage
    }

    /// HUD の輝度をマスクにして、その場所の背景を暗くする。
    ///
    /// screen 合成は背景を明るくすることしかできないため、明るい背景では HUD が白へ潰れて
    /// 「薄い」印象になる。先に背景を落としておくと R と B が引かれ、緑が濃く出る。
    /// HUD が黒い (＝素通しの) 場所は輝度 0 なのでマスクも 0 になり、背景はそのまま残る。
    private func dimmed(_ camera: CIImage, under hud: CIImage) -> CIImage {
        guard density > 0 else { return camera }

        // 1 - density × luma(hud) を全チャンネルに作る。CIColorMatrix 1 枚で足りる
        let weights = (r: -density * 0.299, g: -density * 0.587, b: -density * 0.114)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = hud
        let vector = CIVector(x: CGFloat(weights.r), y: CGFloat(weights.g), z: CGFloat(weights.b), w: 0)
        matrix.rVector = vector
        matrix.gVector = vector
        matrix.bVector = vector
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let inverseMask = matrix.outputImage else { return camera }

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = inverseMask
        multiply.backgroundImage = camera
        return multiply.outputImage ?? camera
    }

    /// 実機は緑単色ディスプレイなので、輝度だけ残して単色に着色し、輝度ゲインを掛ける。
    ///
    /// 単色化 (hue=s=0 相当) は luma 変換なので、緑で描かれている元画面はここで暗くなる
    /// (実測で文字の G 最大 255 → 186.2)。ゲインはその損失を戻し、さらに実機の印象に寄せるためのもの。
    /// 係数は 1 本の CIColorMatrix にまとめて掛け、最後に 0…1 へクランプして screen 合成を素直に保つ。
    private func styled(_ image: CIImage) -> CIImage {
        var source = image

        if tint != nil {
            let desaturate = CIFilter.colorControls()
            desaturate.inputImage = image
            desaturate.saturation = 0
            source = desaturate.outputImage ?? image
        }

        // 単色化していない場合はゲインだけの対角行列になる
        let factors = tint ?? (r: 1, g: 1, b: 1)
        guard tint != nil || gain != 1 else { return source }

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = source
        matrix.rVector = CIVector(x: CGFloat(factors.r * gain), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(factors.g * gain), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(factors.b * gain), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let boosted = matrix.outputImage else { return source }

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = boosted
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? boosted
    }

    /// HUD を hudFrac の高さにスケールし、中央 + オフセットへ置いて、残りを黒で埋める。
    /// 黒は screen 合成に寄与しない ＝ 素通し。
    private func layout(hud: CIImage, in output: CGRect) -> CIImage {
        let targetHeight = (output.height * Config.hudFrac / 2).rounded() * 2
        let scale = targetHeight / hud.extent.height
        let scaled = hud.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // CoreImage は Y 軸が上向き、ffmpeg は下向きなので DY の符号を反転して合わせる
        let dx = (output.width - scaled.extent.width) / 2 + Config.hudDX
        let dy = (output.height - scaled.extent.height) / 2 - Config.hudDY
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: output.minX + dx - scaled.extent.minX,
            y: output.minY + dy - scaled.extent.minY
        ))

        let black = CIImage(color: .black).cropped(to: output)
        return placed.composited(over: black).cropped(to: output)
    }
}
