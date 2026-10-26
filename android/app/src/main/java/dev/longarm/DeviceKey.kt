package dev.longarm

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import kotlin.math.abs

/**
 * This phone's long-term identity for internet connections: a P-256 key in the Android Keystore
 * (hardware-backed where the phone has it), so it can sign but never be copied off the phone.
 * The Mac learns the public half at home, over the paired link ("phone-key"), and checks every
 * connection offer against it. Ids are the SHA-256 of the public key (SPKI DER), base64url.
 */
object DeviceKey {
    private const val ALIAS = "longarm-device"

    private val keyStore by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }

    /** SPKI DER. */
    val publicKey: ByteArray
        get() {
            privateKey()   // makes the key on first use
            return keyStore.getCertificate(ALIAS).publicKey.encoded
        }

    val id: String get() = idOf(publicKey)

    fun idOf(publicKey: ByteArray): String =
        Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(publicKey), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    /** ECDSA with SHA-256, DER-encoded: what CryptoKit on the Mac expects. */
    fun sign(data: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey())
        update(data)
        sign()
    }

    fun isValid(signature: ByteArray, data: ByteArray, publicKey: ByteArray): Boolean = runCatching {
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(publicKey))
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(key)
            update(data)
            verify(signature)
        }
    }.getOrDefault(false)

    private fun privateKey(): PrivateKey {
        (keyStore.getKey(ALIAS, null) as? PrivateKey)?.let { return it }
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
            initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
            )
        }.generateKeyPair()
        return keyStore.getKey(ALIAS, null) as PrivateKey
    }
}

/**
 * Connection setup between this phone and its Mac, signed end to end with their [DeviceKey]s so
 * the rendezvous server can pass it along but not forge or redirect it. Matches SignedSignal on
 * the Mac: {payload: JSON text, sig: base64}, signed over "longarm-signal-v1\n" + payload.
 */
object SignedSignal {
    private fun signed(payload: String) = "longarm-signal-v1\n$payload".toByteArray()

    fun seal(fields: JSONObject, from: String, to: String): JSONObject {
        val payload = fields.put("from", from).put("to", to).put("ts", System.currentTimeMillis()).toString()
        return JSONObject().put("payload", payload)
            .put("sig", Base64.encodeToString(DeviceKey.sign(signed(payload)), Base64.NO_WRAP))
    }

    /** The payload, if [publicKey] signed it, it's from [from] to [me], and it's recent. */
    fun open(data: JSONObject, from: String, me: String, publicKey: ByteArray): JSONObject? {
        val payload = data.optString("payload").takeIf { it.isNotEmpty() } ?: return null
        val signature = runCatching { Base64.decode(data.optString("sig"), Base64.DEFAULT) }.getOrNull() ?: return null
        if (!DeviceKey.isValid(signature, signed(payload), publicKey)) return null
        val fields = runCatching { JSONObject(payload) }.getOrNull() ?: return null
        if (fields.optString("from") != from || fields.optString("to") != me) return null
        if (abs(System.currentTimeMillis() - fields.optLong("ts")) > 10 * 60_000) return null
        return fields
    }
}
