package dev.longarm

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume

/**
 * The live link to the paired Mac: one TLS WebSocket, pinned to the Mac's certificate, carrying
 * remote control messages one way and the screen's video the other (see [Remote]). Reconnects on
 * its own, trying the last known address, then USB (adb reverse → localhost), then Bonjour.
 */
object MacLink {
    enum class Status { Unpaired, Connecting, Searching, Connected }

    data class State(
        val status: Status = Status.Unpaired,
        val macName: String = "",
        val via: String = "",   // "Wi-Fi" or "USB"
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var store: PairingStore
    private lateinit var discovery: Discovery
    private lateinit var deviceName: String
    private var loop: Job? = null
    private var socket: WebSocket? = null

    fun init(context: Context) {
        store = PairingStore(context)
        discovery = Discovery(context)
        deviceName = Settings.Global.getString(context.contentResolver, "device_name") ?: Build.MODEL
        store.load()?.let { p -> _state.update { it.copy(status = Status.Connecting, macName = p.macName) } }
    }

    val pairing: Pairing? get() = store.load()

    fun pair(pairing: Pairing) {
        store.save(pairing)
        stop()
        _state.value = State(status = Status.Connecting, macName = pairing.macName)
        start()
    }

    fun forget() {
        stop()
        store.clear()
        _state.value = State()
    }

    /** Starts (or keeps) the reconnect loop. Called by [LinkService]. */
    fun start() {
        if (loop?.isActive == true || store.load() == null) return
        loop = scope.launch { connectLoop() }
    }

    fun stop() {
        loop?.cancel()
        loop = null
        socket?.cancel()
        socket = null
    }

    fun send(message: JSONObject): Boolean = socket?.send(message.toString()) ?: false

    /** A binary message, e.g. microphone audio (see [PhoneMic]). */
    fun sendBytes(bytes: ByteArray): Boolean = socket?.send(bytes.toByteString()) ?: false

    // MARK: connection

    private suspend fun connectLoop() {
        var backoffMs = 1_000L
        while (scope.isActive) {
            val pairing = store.load() ?: return
            val client = pinnedClient(pairing.fingerprint)
            var connected = false
            for ((host, via) in listOf(pairing.host to "Wi-Fi", "127.0.0.1" to "USB")) {
                _state.update { it.copy(status = Status.Connecting, macName = pairing.macName) }
                if (connectAndWait(client, pairing, host, via)) { connected = true; break }
            }
            if (connected) { backoffMs = 1_000L; continue }   // dropped after a good session: retry at once

            // The Mac's address may have changed (DHCP): look it up over Bonjour.
            _state.update { it.copy(status = Status.Searching) }
            val found = discovery.find(pairing.macId, timeoutMs = 4_000)
            if (found != null && (found.host != pairing.host || found.port != pairing.port)) {
                store.save(pairing.copy(host = found.host, port = found.port))
                continue
            }
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(8_000L)
        }
    }

    /** Opens one connection and suspends until it closes. Returns true if it ever opened. */
    private suspend fun connectAndWait(client: OkHttpClient, pairing: Pairing, host: String, via: String): Boolean =
        suspendCancellableCoroutine { continuation ->
            var opened = false
            val request = Request.Builder()
                .url("wss://$host:${pairing.port}/")
                .header("Authorization", "Bearer ${pairing.token}")
                .build()
            val ws = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened = true
                    scope.launch {
                        socket = webSocket
                        _state.update { it.copy(status = Status.Connected, via = via) }
                        send(JSONObject().put("type", "hello").put("device", deviceName))
                        Remote.onConnected()
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    scope.launch {
                        val message = runCatching { JSONObject(text) }.getOrNull() ?: return@launch
                        val type = message.optString("type")
                        if (type == "hello") _state.update { it.copy(macName = message.optString("mac", it.macName)) }
                        else Remote.handle(type, message)
                    }
                }

                // Binary messages are video frames, decoded on this thread rather than the main one.
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) = Remote.onFrame(bytes.toByteArray())

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish(webSocket)
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = finish(webSocket)

                private fun finish(webSocket: WebSocket) {
                    scope.launch {
                        if (socket === webSocket) socket = null
                        Remote.onDisconnected()
                        if (continuation.isActive) continuation.resume(opened)
                    }
                }
            })
            continuation.invokeOnCancellation { ws.cancel() }
        }

    // MARK: TLS pinning

    /** Trusts exactly one certificate: the Mac's, identified by the fingerprint from the QR code. */
    private fun pinnedClient(fingerprint: String): OkHttpClient {
        val trustManager = @SuppressLint("CustomX509TrustManager") object : X509TrustManager {
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val actual = MessageDigest.getInstance("SHA-256").digest(chain.first().encoded)
                if (!MessageDigest.isEqual(actual, fingerprint.hexToBytes())) {
                    throw CertificateException("Certificate doesn't match the paired Mac")
                }
            }

            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                throw CertificateException("Client certificates not supported")

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), null) }
        return OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, trustManager)
            // The pinned certificate proves identity; the Mac's IP changes, so hostnames can't.
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(3, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(10, TimeUnit.SECONDS)
            .build()
    }

    private fun String.hexToBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
