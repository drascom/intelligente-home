import SwiftUI

struct ContentView: View {
    @StateObject private var manager = RoomManager()

    @State private var url: String = "wss://vox.tailfe7e95.ts.net"
    @State private var token: String = ""

    private var isConnected: Bool {
        manager.connectionState == "connected"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sunucu") {
                    TextField("Server URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $token)
                            .frame(minHeight: 90)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.system(.caption, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                    }
                }

                Section("Bağlantı") {
                    HStack {
                        Button {
                            Task { await manager.connect(url: url, token: token) }
                        } label: {
                            Label("Bağlan", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isConnected)

                        Spacer()

                        Button(role: .destructive) {
                            Task { await manager.disconnect() }
                        } label: {
                            Label("Bağlantıyı Kes", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isConnected)
                    }

                    Toggle(isOn: Binding(
                        get: { manager.isMicEnabled },
                        set: { _ in Task { await manager.toggleMic() } }
                    )) {
                        Label("Mikrofon", systemImage: manager.isMicEnabled ? "mic.fill" : "mic.slash.fill")
                    }
                    .disabled(!isConnected)
                }

                Section("Durum") {
                    LabeledContent("Durum", value: manager.connectionState)
                    LabeledContent("Uzak katılımcı", value: "\(manager.remoteParticipants.count)")
                    if !manager.remoteParticipants.isEmpty {
                        ForEach(manager.remoteParticipants, id: \.self) { p in
                            Text("• \(p)").font(.caption)
                        }
                    }
                    if let err = manager.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Günlük") {
                    ScrollView {
                        ScrollViewReader { proxy in
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(manager.log.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(.caption2, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .onChange(of: manager.log.count) { _ in
                                if let last = manager.log.indices.last {
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            .navigationTitle("MateLiveKit")
        }
    }
}

#Preview {
    ContentView()
}
