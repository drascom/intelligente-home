import SwiftUI

/// A multiplatform view that shows voice-specific interaction controls.
///
/// Shows the agent participant view (avatar or audio visualizer).
struct VoiceInteractionView: View {
    var body: some View {
        AgentView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}
