package com.oriolgomez.nvdr.speech

import android.content.Context
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

data class VoiceOption(val id: String, val name: String, val language: String)

/**
 * Wraps Android [TextToSpeech] to speak the slave's utterances locally — the
 * Android analog of the iOS/macOS `SpeechOutput`. The synthesizer is configured
 * as accessibility speech so the system treats it like a screen reader.
 *
 * `speak` calls before the engine finishes initializing are buffered (only the
 * most recent is kept) and flushed once ready, so early relay chatter isn't lost.
 */
class SpeechOutput(context: Context) {
    private val ready = MutableStateFlow(false)
    val isReady: StateFlow<Boolean> = ready.asStateFlow()

    private var rate: Float = 1.0f
    private var voiceId: String? = null
    private var pending: String? = null
    private var counter: Int = 0

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        onInit(status)
    }

    private fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) return
        // USAGE_MEDIA (not ASSISTANCE_ACCESSIBILITY): the latter routes to the
        // accessibility stream, which is silent unless a screen reader drives it.
        // Media plays through the normal output and is governed by the volume keys.
        tts.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        val def = Locale.getDefault()
        tts.language = if (tts.isLanguageAvailable(def) >= TextToSpeech.LANG_AVAILABLE) def else Locale.US
        applyRate()
        applyVoice()
        ready.value = true
        pending?.let { speak(it) }
        pending = null
    }

    fun speak(text: String) {
        if (text.isEmpty()) return
        if (!ready.value) { pending = text; return }
        counter += 1
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, "nvdr-$counter")
    }

    /** Interrupt anything in flight and say [text] now (forwarding on/off notices). */
    fun announce(text: String) {
        if (!ready.value) { pending = text; return }
        counter += 1
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "nvdr-a-$counter")
    }

    fun cancel() {
        if (ready.value) tts.stop()
        pending = null
    }

    fun preview(sample: String = "The quick brown fox jumps over the lazy dog.") =
        announce(sample)

    fun setRate(value: Float) {
        rate = value.coerceIn(0.1f, 4.0f)
        if (ready.value) applyRate()
    }

    fun setVoice(id: String?) {
        voiceId = id
        if (ready.value) applyVoice()
    }

    fun voices(): List<VoiceOption> {
        if (!ready.value) return emptyList()
        val all = runCatching { tts.voices }.getOrNull() ?: return emptyList()
        return all
            .filterNot { it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }
            .map { VoiceOption(id = it.name, name = prettyName(it), language = it.locale.toLanguageTag()) }
            .sortedWith(compareBy({ it.language }, { it.name }))
    }

    fun shutdown() {
        runCatching { tts.stop() }
        runCatching { tts.shutdown() }
    }

    private fun applyRate() {
        tts.setSpeechRate(rate)
    }

    private fun applyVoice() {
        val id = voiceId ?: return
        val match = runCatching { tts.voices }.getOrNull()?.firstOrNull { it.name == id }
        if (match != null) tts.voice = match
    }

    private fun prettyName(v: Voice): String {
        val loc = v.locale
        val lang = loc.getDisplayName(Locale.getDefault()).ifEmpty { loc.toLanguageTag() }
        return "$lang — ${v.name}"
    }
}
