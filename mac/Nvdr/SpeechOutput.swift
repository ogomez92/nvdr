import Foundation
import AVFoundation

/// Speaks lines coming back from the slave NVDA. Each `speak` IPC event is
/// one utterance; `cancel` interrupts the current and queued utterances.
///
/// `AVSpeechSynthesizer` callbacks come on its own queue and we only mutate
/// state from the actor, so this is safe to call from any task.
actor SpeechOutput {
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float

    init(rate: Float = 0.55, voiceIdentifier: String? = nil) {
        self.rate = rate
        // macOS has no `AVAudioSession` — `AVSpeechSynthesizer` plays through
        // the default output device with no session setup required.
        self.voice = Self.resolveVoice(identifier: voiceIdentifier)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = voice
        u.rate = rate
        synth.speak(u)
    }

    func cancel() {
        synth.stopSpeaking(at: .immediate)
    }

    /// Speak a short sample at the current rate/voice. Used by the settings
    /// sheet to give live feedback as the user drags the rate slider.
    func preview(_ sample: String = "The quick brown fox jumps over the lazy dog.") {
        synth.stopSpeaking(at: .immediate)
        speak(sample)
    }

    /// Speak an interrupting local notice (e.g. a forwarding-state change).
    /// Jumps ahead of any queued remote speech so a safety announcement —
    /// "your keyboard is now redirected" — is heard immediately.
    func announce(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        speak(text)
    }

    func setRate(_ r: Float) {
        rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, r))
    }

    func setVoice(identifier: String?) {
        voice = Self.resolveVoice(identifier: identifier)
    }

    private static func resolveVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let id = identifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }
}

/// Plain-data view of an installed voice for display in the settings picker.
/// We pull this on the main actor so SwiftUI can render it directly.
struct VoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let language: String

    static func installed() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceOption(id: $0.identifier, name: $0.name, language: $0.language)
        }
        .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
}
