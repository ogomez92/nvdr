package com.oriolgomez.nvdr.ui

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.oriolgomez.nvdr.AppContainer
import com.oriolgomez.nvdr.net.BridgeClient.Status

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RootScreen(container: AppContainer) {
    var showSettings by remember { mutableStateOf(false) }

    if (showSettings) {
        SettingsScreen(container) { showSettings = false }
        return
    }

    val bridge = container.bridge
    val status by bridge.status.collectAsStateWithLifecycle()
    val forwarding by bridge.forwarding.collectAsStateWithLifecycle()
    val lastSpeech by bridge.lastSpeech.collectAsStateWithLifecycle()
    val log by bridge.log.collectAsStateWithLifecycle()

    // Push saved speech prefs into the engine once (no-ops until TTS is ready).
    LaunchedEffect(Unit) {
        container.speech.setRate(container.settings.speechRate)
        container.speech.setVoice(container.settings.voiceId)
    }

    val context = LocalContext.current
    val accessibilityOn by container.accessibilityRunning.collectAsStateWithLifecycle()
    val running = status !is Status.Idle
    val canForward = status is Status.Ready || status is Status.NvdaNotConnected

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("nvdr") },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            StatusHeader(status)

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(
                    onClick = {
                        if (running) {
                            bridge.stop()
                        } else {
                            container.settings.save()
                            bridge.start(container.settings.snapshot())
                        }
                    },
                ) {
                    Text(if (running) "Disconnect" else "Connect")
                }
                OutlinedButton(onClick = { showSettings = true }) {
                    Text("Settings")
                }
            }

            ForwardingPanel(
                enabled = canForward,
                forwarding = forwarding,
                onToggle = { bridge.setForwarding(it) },
            )

            AccessibilityPanel(
                running = accessibilityOn,
                onEnable = { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
            )

            LastSpeechPanel(lastSpeech)

            LogPanel(log, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatusHeader(status: Status) {
    val (label, color) = statusDisplay(status)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            modifier = Modifier
                .size(14.dp)
                .clip(CircleShape)
                .background(color)
                .semantics { contentDescription = "Status: $label" },
        )
        Text(label, style = MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun ForwardingPanel(enabled: Boolean, forwarding: Boolean, onToggle: (Boolean) -> Unit) {
    Card {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column {
                Text("Forward keystrokes", style = MaterialTheme.typography.titleMedium)
                Text(
                    if (enabled) "Caps Lock + F11 also toggles" else "Connect first",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Switch(checked = forwarding, enabled = enabled, onCheckedChange = onToggle)
        }
    }
}

@Composable
private fun AccessibilityPanel(running: Boolean, onEnable: () -> Unit) {
    Card {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("System-wide capture", style = MaterialTheme.typography.titleMedium)
            Text(
                if (running) {
                    "On — Alt+Tab, the Windows/Meta key, and other system combos are captured while forwarding."
                } else {
                    "Off — Android intercepts some keys (Alt+Tab, Windows/Meta key) before nvdr sees them. " +
                        "Enable the nvdr accessibility service to capture them everywhere."
                },
                style = MaterialTheme.typography.bodySmall,
            )
            if (!running) {
                OutlinedButton(onClick = onEnable) { Text("Open Accessibility settings") }
            }
        }
    }
}

@Composable
private fun LastSpeechPanel(text: String) {
    Card {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
            Text("Last speech", style = MaterialTheme.typography.labelMedium)
            Text(
                text.ifEmpty { "—" },
                style = MaterialTheme.typography.bodyLarge,
            )
        }
    }
}

@Composable
private fun LogPanel(log: List<String>, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    LaunchedEffect(log.size) {
        if (log.isNotEmpty()) listState.animateScrollToItem(log.size - 1)
    }
    Card(modifier = modifier.fillMaxWidth()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            items(log) { line ->
                Text(
                    line,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                )
            }
        }
    }
}

private fun statusDisplay(status: Status): Pair<String, Color> = when (status) {
    Status.Idle -> "Idle" to Color.Gray
    Status.Connecting -> "Connecting…" to Color(0xFFFFA000)
    Status.Authenticating -> "Authenticating…" to Color(0xFFFFA000)
    Status.Ready -> "Ready" to Color(0xFF2E7D32)
    Status.NvdaNotConnected -> "No NVDA in channel" to Color(0xFFFFA000)
    is Status.Disconnected -> "Disconnected (${status.reason})" to Color(0xFFC62828)
    is Status.Failed -> "Failed: ${status.message}" to Color(0xFFC62828)
}
