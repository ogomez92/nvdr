# Release builds ship with minification off (see build.gradle.kts), so these
# rules only matter if you flip isMinifyEnabled = true. SSHJ + BouncyCastle
# load algorithms reflectively, so keep them whole.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class net.schmizz.sshj.** { *; }
-keep class net.i2p.crypto.eddsa.** { *; }
-dontwarn net.schmizz.sshj.**
-dontwarn org.slf4j.**
