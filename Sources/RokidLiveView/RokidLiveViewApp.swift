import SwiftUI

@main
struct RokidLiveViewApp: App {
    @StateObject private var engine = LiveEngine()!

    var body: some Scene {
        Window("RokidLiveView", id: "main") {
            ContentView(engine: engine)
                .onAppear { if SelfTest.isEnabled { SelfTest.run(engine: engine) } }
                .onDisappear { engine.stop() }
        }
        .defaultSize(width: 540, height: 1000)
    }
}
