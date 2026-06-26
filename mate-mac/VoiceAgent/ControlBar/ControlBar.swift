import LiveKitComponents

/// A multiplatform view that shows the control bar: audio/video and chat controls.
/// Available controls depend on the agent features and the track availability.
/// - SeeAlso: ``AgentFeatures``
struct ControlBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia

    @Binding var chat: Bool
    @Binding var showInput: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.voiceEnabled) private var voiceEnabled
    @Environment(\.textEnabled) private var textEnabled

    private enum Constants {
        static let buttonWidth: CGFloat = 16 * .grid
        static let buttonHeight: CGFloat = 11 * .grid
    }

    var body: some View {
        HStack(spacing: .zero) {
            biggerSpacer()
            if voiceEnabled {
                audioControls()
                flexibleSpacer()
            }
            #if os(macOS)
                AudioDeviceSelector()
                    .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                flexibleSpacer()
            #endif
            textInputToggle()
            flexibleSpacer()
            reconnectButton()
            biggerSpacer()
        }
        .buttonStyle(
            ControlBarButtonStyle(
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
        .font(.system(size: 17, weight: .medium))
        .frame(height: 15 * .grid)
        #if !os(visionOS)
            .glass3(cornerRadius: 7.5 * .grid, strong: true)
            .safeAreaPadding(.bottom, 8 * .grid)
            .safeAreaPadding(.horizontal, 16 * .grid)
        #endif
    }

    private func flexibleSpacer() -> some View {
        Spacer()
            .frame(maxWidth: horizontalSizeClass == .regular ? 8 * .grid : 2 * .grid)
    }

    private func biggerSpacer() -> some View {
        Spacer()
            .frame(maxWidth: horizontalSizeClass == .regular ? 8 * .grid : .infinity)
    }

    private func separator() -> some View {
        Rectangle()
            .fill(.separator1)
            .frame(width: 1, height: 3 * .grid)
    }

    private func audioControls() -> some View {
        HStack(spacing: .zero) {
            Spacer()
            AsyncButton(action: localMedia.toggleMicrophone) {
                HStack(spacing: .grid) {
                    Image(systemName: localMedia.isMicrophoneEnabled ? "microphone.fill" : "microphone.slash.fill")
                        .transition(.symbolEffect)
                    BarAudioVisualizer(
                        audioTrack: localMedia.microphoneTrack,
                        barColor: .fg1,
                        barCount: 3,
                        barSpacingFactor: 0.1
                    )
                    .frame(width: 2 * .grid, height: 0.5 * Constants.buttonHeight)
                    .frame(maxHeight: .infinity)
                    .id(localMedia.microphoneTrack?.id)
                }
                .frame(height: Constants.buttonHeight)
                .padding(.horizontal, 2 * .grid)
                .contentShape(Rectangle())
            }
            Spacer()
        }
        .frame(width: Constants.buttonWidth)
    }

    /// Mesaj yazma alanını aç/kapa (input varsayılan gizli; sürekli gerekmiyor).
    private func textInputToggle() -> some View {
        Button {
            showInput.toggle()
        } label: {
            Image(systemName: "text.bubble.fill")
                .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            ControlBarButtonStyle(
                isToggled: showInput,
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
    }

    /// Reconnect / refresh button.
    ///
    /// The app auto-connects and the `autoConnect` loop in ``AppView`` re-dials
    /// the room as soon as the session drops, so a manual "disconnect" only ever
    /// produces an immediate reconnect. We surface that real behaviour here: the
    /// action still tears down the session (`session.end()` + clear history), and
    /// the auto-connect loop brings it right back — i.e. a refresh.
    private func reconnectButton() -> some View {
        AsyncButton {
            await session.end()
            session.restoreMessageHistory([])
        } label: {
            Image(systemName: "arrow.clockwise")
                .frame(width: Constants.buttonWidth, height: Constants.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            ControlBarButtonStyle(
                foregroundColor: .fg1,
                backgroundColor: .bg2,
                borderColor: .separator1
            )
        )
        .help("control.reconnect")
        .accessibilityLabel(Text("control.reconnect"))
        .disabled(!session.isConnected)
    }
}
