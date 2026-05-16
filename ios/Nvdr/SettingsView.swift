import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [VoiceOption] = []

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("SSH bridge") {
                    LabeledTextField("Host", text: $settings.sshHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledIntField("Port", value: $settings.sshPort)
                    LabeledTextField("User", text: $settings.sshUser)
                        .textInputAutocapitalization(.never)
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("NVDA Remote relay") {
                    LabeledTextField("Relay host", text: $settings.relayHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledIntField("Port", value: $settings.relayPort)
                    LabeledTextField("Channel key", text: $settings.channel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledTextField("Pinned fingerprint (sha-256, blank=TOFU)", text: $settings.fingerprint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Insecure (skip TLS verify)", isOn: $settings.insecure)
                }

                Section("Local input") {
                    Picker("NVDA modifier", selection: $settings.nvdaModifier) {
                        ForEach(NvdaModifier.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Picker("Option (⌥) sends", selection: $settings.optionMapping) {
                        ForEach(ModifierMapping.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Picker("Command (⌘) sends", selection: $settings.commandMapping) {
                        ForEach(ModifierMapping.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Text("CapsLock is closest to NVDA's default Insert. If iOS / VoiceOver eats CapsLock events, switch to VO keys (Ctrl+Option) — the standard VoiceOver convention.")
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
            .navigationTitle("Settings")
            .task {
                voices = VoiceOption.installed()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        settings.save()
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
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

/// An editable port / numeric field. Uses `.numberPad` so the user gets a
/// digit keyboard, not the +/- stepper.
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
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Multi-line OpenSSH private-key paste area. Headed by a "Paste from
/// clipboard" affordance because a long PEM is a pain to type on iOS.
private struct PrivateKeyEditor: View {
    @Binding var pem: String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Private key (OpenSSH)")
                Spacer()
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let s = UIPasteboard.general.string {
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
                .textInputAutocapitalization(.never)
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
