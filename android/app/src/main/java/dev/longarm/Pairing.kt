package dev.longarm

import android.content.Context
import android.net.Uri

/** Everything needed to reach and trust one Mac, as encoded in its longarm://pair QR code. */
data class Pairing(
    val host: String,
    val port: Int,
    val token: String,
    /** SHA-256 of the Mac's TLS certificate (lowercase hex); the only certificate we accept. */
    val fingerprint: String,
    val macId: String,
    val macName: String,
    /** For internet connections, learned over the home link: the Mac's public key (SPKI DER,
     *  base64; see [DeviceKey]) and its rendezvous server. */
    val macKey: String? = null,
    val rendezvous: String? = null,
) {
    companion object {
        fun parse(link: String): Pairing? {
            val uri = runCatching { Uri.parse(link.trim()) }.getOrNull() ?: return null
            if (uri.scheme != "longarm" || uri.host != "pair") return null
            return Pairing(
                host = uri.getQueryParameter("h") ?: return null,
                port = uri.getQueryParameter("p")?.toIntOrNull() ?: return null,
                token = uri.getQueryParameter("t")?.takeIf { it.isNotEmpty() } ?: return null,
                fingerprint = uri.getQueryParameter("f")?.lowercase()?.takeIf { it.length == 64 } ?: return null,
                macId = uri.getQueryParameter("id") ?: return null,
                macName = uri.getQueryParameter("n") ?: "Mac",
            )
        }
    }
}

class PairingStore(context: Context) {
    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    fun load(): Pairing? {
        return Pairing(
            host = prefs.getString("host", null) ?: return null,
            port = prefs.getInt("port", 0).takeIf { it > 0 } ?: return null,
            token = prefs.getString("token", null) ?: return null,
            fingerprint = prefs.getString("fingerprint", null) ?: return null,
            macId = prefs.getString("macId", null) ?: return null,
            macName = prefs.getString("macName", null) ?: "Mac",
            macKey = prefs.getString("macKey", null),
            rendezvous = prefs.getString("rendezvous", null),
        )
    }

    fun save(pairing: Pairing) {
        prefs.edit()
            .putString("host", pairing.host)
            .putInt("port", pairing.port)
            .putString("token", pairing.token)
            .putString("fingerprint", pairing.fingerprint)
            .putString("macId", pairing.macId)
            .putString("macName", pairing.macName)
            .putString("macKey", pairing.macKey)
            .putString("rendezvous", pairing.rendezvous)
            .apply()
    }

    fun clear() = prefs.edit().clear().apply()
}
