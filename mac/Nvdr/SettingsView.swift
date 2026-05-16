import AppKit
import SwiftUI

/// nvdr's preferences, presented in the standard macOS `Settings` scene.
/// Changes apply live; the form persists to `UserDefaults` when it closes.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @State private var voices: [VoiceOption] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("SSH bridge") {
                LabeledTextField("Host", text: $settings.sshHost)
                    .autocorrectionDisabled()
                LabeledIntField("Port", value: $settings.sshPort)
                LabeledTextField("User", text: $settings.sshUser)
                    .autocorrectionDisabled()
                Picker("Auth", selection: $settings.sshAuthMode) {
                    ForEach(SSHAuthMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                if settings.sshAuthMode == .password {
                    LabeledSecureField("Password", text: $settings.sshPassword)
                } else {
                    PrivateKeyEditor(pem: $settings.sshPrivateKeyPEM)
                    LabeledSecureField("Key passphrase (blank if none)", text: $settings.sshPrivateKeyPassphrase)
                }
                LabeledTextField("Remote nvdr command", text: $settings.remoteNvdrCommand)
                    .autocorrectionDisabled()
            }

            Section("NVDA Remote relay") {
                LabeledTextField("Relay host", text: $settings.relayHost)
                    .autocorrectionDisabled()
                LabeledIntField("Port", value: $settings.relayPort)
                LabeledTextField("Channel key", text: $settings.channel)
                    .autocorrectionDisabled()
                LabeledTextField("Pinned fingerprint (sha-256, blank=TOFU)", text: $settings.fingerprint)
                    .autocorrectionDisabled()
                Toggle("Insecure (skip TLS verify)", isOn: $settings.insecure)
            }

            Section("Local input") {
                Picker("NVDA modifier", selection: $settings.nvdaModifier) {
                    ForEach(NvdaModifier.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Left Option (⌥) sends", selection: $settings.leftOptionMapping) {
                    ForEach(ModifierMapping.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Right Option (⌥) sends", selection: $settings.rightOptionMapping) {
                    ForEach(ModifierMapping.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Picker("Command (⌘) sends", selection: $settings.commandMapping) {
                    ForEach(ModifierMapping.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                Text("The NVDA modifier doubles as the forwarding toggle: hold it and press F11. Caps Lock is closest to NVDA's default Insert and is read off the hardware, so it works as a held key. VO keys (Ctrl+Option) is the alternative if you prefer not to use Caps Lock.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Speech") {
                SpeechRateRow()
                VoicePickerRow(voices: voices)
                Button("Preview speech", systemImage: "speaker.wave.2") {
                    bridge.previewSpeech()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 520)
        .task {
            voices = VoiceOption.installed()
        }
        .onDisappear {
            settings.save()
        }
    }
}

private struct SpeechRateRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading) {
            HStack {
                Text("Rate")
                Spacer()
                Text(settings.speechRate, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            // AVSpeech rate range is 0.0 – 1.0 with 0.5 = "default". The
            // synth doesn't react to values below 0.05 (it just stops
            // speaking), so clamp the slider above that.
            Slider(value: $settings.speechRate, in: 0.1...1.0, step: 0.05)
                .onChange(of: settings.speechRate) { _, newValue in
                    bridge.setSpeechRate(newValue)
                    bridge.previewSpeech("Rate \(Int(newValue * 100))")
                }
        }
    }
}

private struct VoicePickerRow: View {
    let voices: [VoiceOption]
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        @Bindable var settings = settings
        Picker("Voice", selection: Binding(
            get: { settings.voiceIdentifier ?? "" },
            set: { newID in
                let value: String? = newID.isEmpty ? nil : newID
                settings.voiceIdentifier = value
                bridge.setSpeechVoice(value)
                bridge.previewSpeech()
            }
        )) {
            Text("System default").tag("")
            ForEach(voices) { v in
                Text("\(v.name) (\(v.language))").tag(v.id)
            }
        }
    }
}

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        LabeledContent(label) {
            SecureField(label, text: $text)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// An editable port / numeric field.
private struct LabeledIntField: View {
    let label: String
    @Binding var value: Int

    init(_ label: String, value: Binding<Int>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, value: $value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Multi-line OpenSSH private-key paste area, with a clipboard affordance.
private struct PrivateKeyEditor: View {
    @Binding var pem: String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Private key (OpenSSH)")
                Spacer()
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        pem = s
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                Button("Clear", systemImage: "xmark.circle") { pem = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .disabled(pem.isEmpty)
            }
            TextEditor(text: $pem)
                .font(.caption.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if pem.isEmpty {
                        Text("-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
