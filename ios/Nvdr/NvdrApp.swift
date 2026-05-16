import SwiftUI

@main
struct NvdrApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient

    init() {
        let s = AppSettings()
        let speech = SpeechOutput(rate: s.speechRate, voiceIdentifier: s.voiceIdentifier)
        _settings = State(initialValue: s)
        _bridge = State(initialValue: BridgeClient(speech: speech))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
        }
    }
}
