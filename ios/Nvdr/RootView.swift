import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @State private var showingSettings = false

    var body: some View {
        @Bindable var bridge = bridge
        NavigationStack {
            VStack(spacing: 0) {
                StatusHeader()
                ConnectionControls(showingSettings: $showingSettings)
                Divider()
                ForwardingPanel()
                Divider()
                LastSpeechPanel()
                Divider()
                LogPanel()
                // Capture sits at the bottom and is always present so it can
                // hold first-responder. Zero height — it doesn't render.
                KeyboardCapture(bridge: bridge, settings: settings)
                    .frame(height: 0)
            }
            .navigationTitle("nvdr")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gear") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}

private struct StatusHeader: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(label)
                .bold()
            Spacer()
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch bridge.status {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .ready: return "Ready"
        case .nvdaNotConnected: return "Connected, no NVDA on channel"
        case .disconnected(let r): return "Disconnected (\(r))"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var color: Color {
        switch bridge.status {
        case .ready: return .green
        case .nvdaNotConnected: return .yellow
        case .connecting, .authenticating: return .orange
        case .failed: return .red
        case .disconnected, .idle: return .secondary
        }
    }
}

private struct ConnectionControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Binding var showingSettings: Bool

    var body: some View {
        HStack {
            Button(connectLabel, systemImage: "network") {
                if connected { bridge.stop() } else { bridge.start(settings) }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Button("Edit Settings", systemImage: "slider.horizontal.3") {
                showingSettings = true
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    private var connected: Bool {
        switch bridge.status {
        case .ready, .connecting, .authenticating, .nvdaNotConnected: return true
        default: return false
        }
    }

    private var connectLabel: String { connected ? "Disconnect" : "Connect" }
}

private struct ForwardingPanel: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        @Bindable var bridge = bridge
        VStack(alignment: .leading) {
            Toggle("Forward keystrokes to slave", isOn: $bridge.forwardingEnabled)
                .disabled(bridge.status != .ready && bridge.status != .nvdaNotConnected)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var hint: String {
        switch bridge.status {
        case .ready, .nvdaNotConnected:
            return "Toggle on, then a Bluetooth keyboard press is sent to the remote NVDA. Toggle off to interact with the iPhone normally."
        default:
            return "Connect first."
        }
    }
}

private struct LastSpeechPanel: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        VStack(alignment: .leading) {
            Text("Last spoken")
                .font(.headline)
            Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

private struct LogPanel: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        VStack(alignment: .leading) {
            Text("Log")
                .font(.headline)
                .padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(bridge.log.indices, id: \.self) { i in
                        Text(bridge.log[i])
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
