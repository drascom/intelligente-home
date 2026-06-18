import SwiftUI

@main
struct MateLiveKitApp: App {
    // LiveKit's AudioManager manages the AVAudioSession by default
    // (category .playAndRecord, mode .videoChat with built-in echo cancellation),
    // so we intentionally do NOT configure AVAudioSession manually here.
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
