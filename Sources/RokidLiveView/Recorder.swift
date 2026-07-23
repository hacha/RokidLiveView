import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// 画面に出ている合成映像をそのまま mp4 に保存する。
///
/// 音声はグラスのマイクを scrcpy の 3 本目 (--no-video --audio-source=mic) で別録りし、
/// 停止時に ffmpeg で多重化する。ライブ表示側の scrcpy は --no-audio のまま
/// (スピーカーに出すとハウリングと遅延の原因になるため)。
@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutput: URL?
    @Published private(set) var lastError: String?

    /// 出力フレームレート。
    /// プレビューは 60fps で回るが、録画は固定 30fps の CFR にする
    /// (実カメラが約 30fps なので重複フレームを書かずに済み、PTS も規則的になる)。
    private static let frameRate: Int32 = 30

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioProcess: Process?
    private var videoURL: URL?
    private var audioURL: URL?
    private var timer: Timer?

    /// 次に書き込むフレーム番号 (PTS = frameIndex / frameRate)
    private var frameIndex: Int64 = 0
    /// 最初の映像フレームを書いた実時刻。音声とのズレ補正に使う
    private var videoStartDate: Date?

    func start(size: CGSize) {
        guard !isRecording else { return }
        lastError = nil

        let directory: URL
        do {
            directory = try Config.ensureOutputDirectory()
        } catch {
            lastError = "Cannot create the output directory: \(error.localizedDescription)"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let video = directory.appendingPathComponent("live-\(stamp).mp4")
        let audio = directory.appendingPathComponent("live-\(stamp).m4a")

        do {
            let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                ]
            )
            guard writer.canAdd(input) else {
                lastError = "AVAssetWriter rejected the video input"
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                lastError = "Cannot start recording: \(writer.error?.localizedDescription ?? "unknown")"
                return
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.videoURL = video
            self.audioURL = audio
            self.frameIndex = 0
            self.videoStartDate = nil
        } catch {
            lastError = "Cannot start recording: \(error.localizedDescription)"
            return
        }

        audioProcess = ScrcpyController.startAudioRecorder(to: audio)
        if audioProcess == nil {
            // 音声だけ落ちても映像は録り続ける
            lastError = "Could not start audio capture; recording video only"
        }

        isRecording = true
        elapsed = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }

    /// 描画ループ (60fps) から毎回呼ばれる。録画中で、かつ次のフレーム時刻に達したときだけ書く。
    nonisolated func append(image: CIImage, using compositor: Compositor) {
        MainActor.assumeIsolated {
            guard isRecording, let adaptor, let input, input.isReadyForMoreMediaData else { return }

            let now = Date()
            if videoStartDate == nil { videoStartDate = now }
            guard let videoStartDate else { return }

            // 実時間から求めた「あるべきフレーム番号」に追いつくまで書かない = 固定 30fps CFR
            let due = Int64(now.timeIntervalSince(videoStartDate) * Double(Self.frameRate))
            guard due >= frameIndex, let pool = adaptor.pixelBufferPool else { return }

            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { return }

            compositor.ciContext.render(image, to: buffer, bounds: image.extent, colorSpace: compositor.colorSpace)
            adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: Self.frameRate))
            frameIndex += 1
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        // scrcpy は SIGTERM で録画を確定して正常終了する
        audioProcess?.terminate()
        let audioProcess = self.audioProcess
        self.audioProcess = nil

        input?.markAsFinished()
        let writer = self.writer
        let video = videoURL
        let audio = audioURL
        let videoStart = videoStartDate
        self.writer = nil
        self.input = nil
        self.adaptor = nil

        writer?.finishWriting { [weak self] in
            audioProcess?.waitUntilExit()
            let merged = Self.mux(video: video, audio: audio, videoStart: videoStart)
            Task { @MainActor in
                self?.lastOutput = merged ?? video
                if merged == nil, audio != nil {
                    self?.lastError = "Muxing the audio failed; saved video only"
                }
            }
        }
    }

    /// 映像 mp4 と音声 m4a を再エンコードなしで 1 本にまとめる。失敗したら nil (映像は残す)。
    ///
    /// 音声側の scrcpy は起動に 1 秒前後かかるので、そのぶん音声の先頭が遅れて始まる。
    /// オフライン合成が birthtime で頭を揃えるのと同じ考え方で、
    /// 音声ファイルの作成時刻と映像の開始時刻の差を -itsoffset で補正する。
    private nonisolated static func mux(video: URL?, audio: URL?, videoStart: Date?) -> URL? {
        guard let video, let audio,
              FileManager.default.fileExists(atPath: audio.path),
              FileManager.default.isExecutableFile(atPath: Config.ffmpegPath) else { return nil }

        var offset = 0.0
        if let videoStart,
           let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
           let audioStart = attributes[.creationDate] as? Date {
            offset = audioStart.timeIntervalSince(videoStart)
        }

        let merged = video.deletingPathExtension().appendingPathExtension("av.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Config.ffmpegPath)
        process.arguments = [
            "-y",
            "-i", video.path,
            "-itsoffset", String(format: "%.3f", offset), "-i", audio.path,
            "-map", "0:v", "-map", "1:a",
            "-c", "copy", "-shortest", merged.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: merged.path)[.size] as? Int,
              size > 0 else { return nil }

        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: audio)
        return merged
    }
}
