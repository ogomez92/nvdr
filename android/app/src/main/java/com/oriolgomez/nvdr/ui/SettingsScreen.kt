package com.oriolgomez.nvdr.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.oriolgomez.nvdr.AppContainer
import com.oriolgomez.nvdr.settings.AppSettings
import com.oriolgomez.nvdr.settings.ModifierMapping
import com.oriolgomez.nvdr.settings.NvdaModifier
import com.oriolgomez.nvdr.settings.SSHAuthMode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(container: AppContainer, onBack: () -> Unit) {
    val settings = container.settings
    val speech = container.speech

    val save = {
        settings.save()
        onBack()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = save) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Save and back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionHeader("SSH bridge")
            Field("Host", settings.sshHost) { settings.sshHost = it }
            IntField("Port", settings.sshPort) { settings.sshPort = it }
            Field("User", settings.sshUser) { settings.sshUser = it }

            EnumChooser(
                current = settings.sshAuthMode,
                options = SSHAuthMode.entries,
                label = { it.label },
                onSelect = { settings.sshAuthMode = it },
            )
            if (settings.sshAuthMode == SSHAuthMode.Password) {
                Field("Password", settings.sshPassword, secret = true) { settings.sshPassword = it }
            } else {
                Field(
                    "Private key (OpenSSH PEM)",
                    settings.sshPrivateKeyPem,
                    singleLine = false,
                ) { settings.sshPrivateKeyPem = it }
                Field("Key passphrase", settings.sshPrivateKeyPassphrase, secret = true) {
                    settings.sshPrivateKeyPassphrase = it
                }
            }
            Field("Remote nvdr command", settings.remoteNvdrCommand) { settings.remoteNvdrCommand = it }

            HorizontalDivider()
            SectionHeader("NVDA Remote relay")
            Field("Relay host", settings.relayHost) { settings.relayHost = it }
            IntField("Relay port", settings.relayPort) { settings.relayPort = it }
            Field("Channel", settings.channel) { settings.channel = it }
            Field("Cert fingerprint (optional)", settings.fingerprint) { settings.fingerprint = it }
            SwitchRow("Insecure (skip cert check)", settings.insecure) { settings.insecure = it }

            HorizontalDivider()
            SectionHeader("Local input")
            LabeledRow("NVDA modifier (toggle base)")
            EnumChooser(
                current = settings.nvdaModifier,
                options = NvdaModifier.entries,
                label = { it.label },
                onSelect = { settings.nvdaModifier = it },
            )
            LabeledRow("Left Alt sends")
            EnumChooser(
                current = settings.leftAltMapping,
                options = ModifierMapping.entries,
                label = { it.label },
                onSelect = { settings.leftAltMapping = it },
            )
            LabeledRow("Right Alt sends")
            EnumChooser(
                current = settings.rightAltMapping,
                options = ModifierMapping.entries,
                label = { it.label },
                onSelect = { settings.rightAltMapping = it },
            )
            LabeledRow("Meta / ⌘ sends")
            EnumChooser(
                current = settings.metaMapping,
                options = ModifierMapping.entries,
                label = { it.label },
                onSelect = { settings.metaMapping = it },
            )

            HorizontalDivider()
            SectionHeader("Speech")
            SpeechRateRow(
                rate = settings.speechRate,
                onChange = {
                    settings.speechRate = it
                    speech.setRate(it)
                },
                onPreview = {
                    speech.setRate(settings.speechRate)
                    speech.preview()
                },
            )
            VoicePicker(
                speech = speech,
                currentId = settings.voiceId,
                onSelect = {
                    settings.voiceId = it
                    speech.setVoice(it)
                    speech.preview() // speak a sample in the chosen voice
                },
            )
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium)
}

@Composable
private fun LabeledRow(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge)
}

@Composable
private fun Field(
    label: String,
    value: String,
    secret: Boolean = false,
    singleLine: Boolean = true,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = singleLine,
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = if (secret) KeyboardOptions(keyboardType = KeyboardType.Password) else KeyboardOptions.Default,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun IntField(label: String, value: Int, onValueChange: (Int) -> Unit) {
    var text by remember(value) { mutableStateOf(value.toString()) }
    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it.filter(Char::isDigit)
            text.toIntOrNull()?.let(onValueChange)
        },
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    androidx.compose.foundation.layout.Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(label)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> EnumChooser(
    current: T,
    options: List<T>,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, option ->
            SegmentedButton(
                selected = current == option,
                onClick = { onSelect(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
            ) {
                Text(label(option))
            }
        }
    }
}

@Composable
private fun SpeechRateRow(rate: Float, onChange: (Float) -> Unit, onPreview: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        LabeledRow("Speech rate: ${"%.1f".format(rate)}×")
        Slider(
            value = rate,
            onValueChange = onChange,
            onValueChangeFinished = onPreview, // speak a sample at the new rate on release
            valueRange = 0.5f..3.0f,
        )
        Button(onClick = onPreview) { Text("Preview voice") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VoicePicker(
    speech: com.oriolgomez.nvdr.speech.SpeechOutput,
    currentId: String?,
    onSelect: (String?) -> Unit,
) {
    val ready by speech.isReady.collectAsStateWithLifecycle()
    val voices = remember(ready) { if (ready) speech.voices() else emptyList() }
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = voices.firstOrNull { it.id == currentId }?.name ?: "System default"

    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = !expanded }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text("Voice") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.menuAnchor().fillMaxWidth(),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text("System default") },
                onClick = { onSelect(null); expanded = false },
            )
            voices.forEach { voice ->
                DropdownMenuItem(
                    text = { Text(voice.name) },
                    onClick = { onSelect(voice.id); expanded = false },
                )
            }
        }
    }
}
