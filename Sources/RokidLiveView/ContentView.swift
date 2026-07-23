import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: LiveEngine
    @ObservedObject private var recorder: Recorder
    @ObservedObject private var scrcpy: ScrcpyController

    init(engine: LiveEngine) {
        self.engine = engine
        self.recorder = engine.recorder
        self.scrcpy = engine.scrcpy
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalPreviewView(engine: engine)
                .ignoresSafeArea()

            controls
                .padding(10)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(12)
        }
        .frame(minWidth: 480, minHeight: 640)
        .background(Color.black)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button(engine.isRunning ? "Stop" : "Start") {
                engine.isRunning ? engine.stop() : engine.start()
            }
            .keyboardShortcut(.return, modifiers: [])

            Button(recorder.isRecording ? "Stop Recording" : "Record") {
                engine.toggleRecording()
            }
            .disabled(!engine.isRunning)

            if recorder.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(String(format: "%.0fs", recorder.elapsed))
                        .monospacedDigit()
                }
            }

            Button("Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }

            Divider().frame(height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.caption)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer()
        }
        .foregroundStyle(.white)
    }

    private var status: String {
        engine.state.message
    }

    /// 補足行。優先度の高い順に 1 つだけ出す。
    private var detail: String? {
        if engine.needsScreenRecordingPermission {
            return "Grant access in System Settings > Privacy & Security > Screen Recording, then relaunch"
        }
        if let error = recorder.lastError { return error }
        if let error = scrcpy.lastError { return error }
        if let output = recorder.lastOutput { return "Saved: \(output.path)" }
        return nil
    }
}
