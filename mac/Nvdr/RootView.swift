import SwiftUI

struct RootView: View {
    @Environment(KeyCapture.self) private var capture

    var body: some View {
        VStack(spacing: 0) {
            if capture.state != .running {
                PermissionsBanner()
                Divider()
            }
            StatusHeader()
            Divider()
            ConnectionControls()
            Divider()
            ForwardingPanel()
            Divider()
            LastSpeechPanel()
            Divider()
            LogPanel()
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 640)
        .toolbar {
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }
}

/// Shown until both the Accessibility and Input Monitoring permissions are
/// granted — without them the keyboard hook can't run.
private struct PermissionsBanner: View {
    @Environment(KeyCapture.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if capture.state == .needsAccessibility {
                    Button("Open Accessibility Settings") {
                        Permissions.openAccessibilitySettings()
                    }
                }
                if capture.state == .needsInputMonitoring {
                    Button("Open Input Monitoring Settings") {
                        Permissions.openInputMonitoringSettings()
                    }
                }
                Button("Recheck") { capture.recheck() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12))
    }

    private var title: String {
        switch capture.state {
        case .needsAccessibility: return "Accessibility permission needed"
        case .needsInputMonitoring: return "Input Monitoring permission needed"
        default: return "Keyboard hook not running"
        }
    }

    private var detail: String {
        switch capture.state {
        case .needsAccessibility:
            return "nvdr needs Accessibility access to capture and forward keystrokes. Enable nvdr in System Settings, then click Recheck."
        case .needsInputMonitoring:
            return "nvdr needs Input Monitoring access to read Caps Lock at the hardware level. Enable nvdr in System Settings, then click Recheck. You may need to quit and reopen nvdr."
        default:
            return "The system-wide keyboard hook is stopped."
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

    var body: some View {
        HStack {
            Button(connectLabel, systemImage: "network") {
                if connected {
                    bridge.stop()
                } else {
                    settings.save()
                    bridge.start(settings)
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            SettingsLink {
                Label("Edit Settings", systemImage: "slider.horizontal.3")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(KeyCapture.self) private var capture

    var body: some View {
        @Bindable var bridge = bridge
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Forward keystrokes to slave", isOn: $bridge.forwardingEnabled)
                .toggleStyle(.switch)
                .disabled(bridge.status != .ready && bridge.status != .nvdaNotConnected)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var gesture: String {
        settings.nvdaModifier == .capsLock ? "Caps Lock + F11" : "Ctrl + Option + F11"
    }

    private var hint: String {
        guard capture.state == .running else {
            return "Grant the keyboard permissions above to forward keystrokes."
        }
        switch bridge.status {
        case .ready, .nvdaNotConnected:
            return "Press \(gesture) anywhere to toggle forwarding. While on, every key — including ⌘Q and ⌘Tab — goes to the remote NVDA and not this Mac."
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
                .textSelection(.enabled)
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
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: .infinity)
    }
}
