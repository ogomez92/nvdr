package com.oriolgomez.nvdr

import android.content.Context
import com.oriolgomez.nvdr.net.BridgeClient
import com.oriolgomez.nvdr.settings.AppSettings
import com.oriolgomez.nvdr.speech.SpeechOutput
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Process-lifetime singletons, created once in [NvdrApp]. Survives Activity
 * recreation (rotation, theme change) so the SSH session and speech engine
 * outlive configuration changes — the Android equivalent of the Swift app
 * owning these as `@State` on the App.
 */
class AppContainer(context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val settings = AppSettings(context)
    val speech = SpeechOutput(context)
    val bridge = BridgeClient(speech, scope)

    /** Whether the optional system-wide key-capture accessibility service is connected. */
    val accessibilityRunning = MutableStateFlow(false)
}
