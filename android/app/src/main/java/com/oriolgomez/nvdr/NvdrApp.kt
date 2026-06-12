package com.oriolgomez.nvdr

import android.app.Application
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

class NvdrApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        // SSHJ needs the full BouncyCastle provider, but Android ships a stripped
        // "BC" under com.android.org.bouncycastle. Replace it with the bundled one
        // so key parsing and modern algorithms (ed25519, rsa-sha2) work.
        Security.removeProvider("BC")
        Security.insertProviderAt(BouncyCastleProvider(), 1)

        container = AppContainer(this)
    }
}
