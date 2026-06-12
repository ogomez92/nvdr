package com.oriolgomez.nvdr.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

private val Blue = Color(0xFF2962FF)
private val BlueDark = Color(0xFF82B1FF)

val LightColors = lightColorScheme(
    primary = Blue,
    secondary = Color(0xFF455A64),
)

val DarkColors = darkColorScheme(
    primary = BlueDark,
    secondary = Color(0xFFB0BEC5),
)
