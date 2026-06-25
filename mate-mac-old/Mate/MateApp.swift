import SwiftUI

@main
struct MateApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var conversation = ConversationManager()

    init() {
        // stdout dosyaya yönlendirilince print'ler blok-tamponlanıyor →
        // log dosyasından canlı takip edilemiyor. Satır tamponuna geç.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(conversation)
                .preferredColorScheme(.dark)
                .onAppear {
                    conversation.attach(settings: settings)
                    conversation.start()
                }
                #if os(macOS)
                .frame(minWidth: 400, idealWidth: 440, minHeight: 680, idealHeight: 800)
                #endif
        }
    }
}
