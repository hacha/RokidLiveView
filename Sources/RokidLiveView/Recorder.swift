import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// 画面に出ている合成映像をそのまま mp4 に保存する。
///
/// 音声はグラスのマイクではなく、この Mac 自身のマイク入力を AVCaptureSession で拾い、
/// 映像と同じ AVAssetWriter に音声トラックとして直接書き込む
/// (グラス側のマイクは adb/scrcpy 経由だと OS のプライバシーポリシーで常に無音化されるため使えない)。
/// ライブ表示側の scrcpy は --no-audio のまま (スピーカーに出すとハウリングと遅延の原因になるため)。
@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutput: URL?
    @Published private(set) var lastError: String?

    /// 停止して保存が確定したら Finder で保存先を開くか。selftest では邪魔なので切る
    var revealsOutputOnStop = true

    /// 出力フレームレート。
    /// プレビューは 60fps で回るが、録画は固定 30fps の CFR にする
    /// (実カメラが約 30fps なので重複フレームを書かずに済み、PTS も規則的になる)。
    private static let frameRate: Int32 = 30

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var captureSession: AVCaptureSession?
    private let audioQueue = DispatchQueue(label: "com.hacha.rokidliveview.audio")
    private var videoURL: URL?
    private var timer: Timer?

    /// 次に書き込むフレーム番号 (PTS = frameIndex / frameRate)
    private var frameIndex: Int64 = 0
    /// 最初の映像フレームを書いた実時刻 (ホストクロック)。音声 PTS をこれ基準に詰め直す
    private var videoStartHostTime: CMTime?

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

            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
            ])
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else {
                lastError = "AVAssetWriter rejected the audio input"
                return
            }
            writer.add(audioInput)

            guard writer.startWriting() else {
                lastError = "Cannot start recording: \(writer.error?.localizedDescription ?? "unknown")"
                return
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.audioInput = audioInput
            self.videoURL = video
            self.frameIndex = 0
            self.videoStartHostTime = nil
        } catch {
            lastError = "Cannot start recording: \(error.localizedDescription)"
            return
        }

        startMicCapture()

        isRecording = true
        elapsed = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
    }

    /// この Mac のマイク (システム標準の入力デバイス) を拾う AVCaptureSession を立てる。
    /// 権限が無い/デバイスが無い場合は映像だけで録り続ける (グラス側マイクと同じフェイルソフト方針)。
    private func startMicCapture() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            setUpMicCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.isRecording || self.writer != nil else { return }
                    if granted {
                        self.setUpMicCapture()
                    } else {
                        self.lastError = "Microphone access denied; recording video only"
                    }
                }
            }
        default:
            lastError = "Microphone access denied; recording video only"
        }
    }

    private func setUpMicCapture() {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            lastError = "No microphone found; recording video only"
            return
        }

        let session = AVCaptureSession()
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(deviceInput) else {
                lastError = "Could not use the microphone; recording video only"
                return
            }
            session.addInput(deviceInput)

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(output) else {
                lastError = "Could not use the microphone; recording video only"
                return
            }
            session.addOutput(output)
        } catch {
            lastError = "Could not use the microphone: \(error.localizedDescription)"
            return
        }

        captureSession = session
        session.startRunning()
    }

    /// 描画ループ (60fps) から毎回呼ばれる。録画中で、かつ次のフレーム時刻に達したときだけ書く。
    nonisolated func append(image: CIImage, using compositor: Compositor) {
        MainActor.assumeIsolated {
            guard isRecording, let adaptor, let input, input.isReadyForMoreMediaData else { return }

            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            if videoStartHostTime == nil { videoStartHostTime = hostTime }
            guard let videoStartHostTime else { return }

            // ホストクロックから求めた「あるべきフレーム番号」に追いつくまで書かない = 固定 30fps CFR
            let elapsedSeconds = CMTimeGetSeconds(CMTimeSubtract(hostTime, videoStartHostTime))
            let due = Int64(elapsedSeconds * Double(Self.frameRate))
            guard due >= frameIndex, let pool = adaptor.pixelBufferPool else { return }

            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { return }

            compositor.ciContext.render(image, to: buffer, bounds: image.extent, colorSpace: compositor.colorSpace)
            adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: Self.frameRate))
            // 描画が間に合わず due が先行していたら、そこまで一気に追いつく (フレーム番号が現実の遅れに固定されるのを防ぐ)
            frameIndex = due + 1
        }
    }

    /// マイクの音声バッファ。ホストクロックの PTS を、映像と同じセッション原点 (最初の映像フレームの時刻) 基準に詰め直して書く。
    ///
    /// `AVCaptureAudioDataOutput` のデリゲートは専用の `audioQueue` から呼ばれる (メインスレッドではない) ので
    /// `append(image:)` と違って `MainActor.assumeIsolated` は使えない (呼ぶとアサーション違反で落ちる)。
    @objc nonisolated func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        Task { @MainActor in
            guard isRecording, let audioInput, audioInput.isReadyForMoreMediaData,
                  let videoStartHostTime else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let rebased = CMTimeSubtract(pts, videoStartHostTime)
            guard rebased >= .zero else { return }

            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: rebased,
                decodeTimeStamp: .invalid
            )
            var rebasedBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &rebasedBuffer
            )
            guard status == noErr, let rebasedBuffer else { return }
            audioInput.append(rebasedBuffer)
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        captureSession?.stopRunning()
        captureSession = nil

        input?.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        let video = videoURL
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        self.audioInput = nil

        writer?.finishWriting { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.lastOutput = video
                if self.revealsOutputOnStop { Self.reveal(video) }
            }
        }
    }

    /// 保存先を Finder で開く。ファイルがあればそれを選択した状態で、無ければフォルダだけ開く。
    private static func reveal(_ output: URL?) {
        if let output, FileManager.default.fileExists(atPath: output.path) {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } else {
            NSWorkspace.shared.open(Config.outputDirectory)
        }
    }
}

extension Recorder: AVCaptureAudioDataOutputSampleBufferDelegate {}
