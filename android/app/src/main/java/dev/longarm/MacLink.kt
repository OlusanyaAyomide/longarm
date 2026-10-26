package dev.longarm

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Base64
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
 * The link to the paired Mac, carrying remote control messages one way and the screen the other
 * (see [Remote]). The owner picks how it connects ([Mode]); it never falls back from one to the other:
 * - Home: one TLS WebSocket, pinned to the Mac's certificate, always on and reconnecting by
 *   itself: the last known address, then USB (adb reverse → localhost), then Bonjour. It's also
 *   where the phone and Mac swap what internet connections need: their keys and the server.
 * - Internet: WebRTC ([InternetLink]), only while remote control is open, and only with the join
 *   code set on the Mac. The right code earns a ticket from the Mac (kept encrypted), which lets
 *   the phone back in without the code until it goes 10 minutes unused.
 */
object MacLink {
    enum class Mode { Home, Internet }

    enum class Status { Unpaired, Idle, Connecting, Searching, Connected }

    data class State(
        val status: Status = Status.Unpaired,
        val macName: String = "",
        val via: String = "",   // "Wi-Fi", "USB" or "Internet"
        val mode: Mode = Mode.Home,
        /** Why the Mac didn't let us in over the internet (a wrong code, say), until the next try. */
        val joinError: String? = null,
        /** The Mac's internet server (its host), once the phone has what [Mode.Internet] needs. */
        val internet: String? = null,
        /** Why the internet connection gave up (the Mac was offline, say). */
        val problem: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var store: PairingStore
    private lateinit var discovery: Discovery
    private lateinit var deviceName: String
    private lateinit var prefs: SharedPreferences
    private var loop: Job? = null
    private var socket: WebSocket? = null

    fun init(context: Context) {
        store = PairingStore(context)
        discovery = Discovery(context)
        prefs = context.getSharedPreferences("link", Context.MODE_PRIVATE)
        deviceName = Settings.Global.getString(context.contentResolver, "device_name") ?: Build.MODEL
        val mode = runCatching { Mode.valueOf(prefs.getString("mode", null) ?: "") }.getOrDefault(Mode.Home)
        store.load()?.let { p -> _state.value = State(waiting(mode), p.macName, mode = mode, internet = internetHost(p)) }
        InternetLink.init(context, deviceName)
        InternetLink.onConnecting = { _state.update { it.copy(status = Status.Connecting) } }
        InternetLink.onJoined = { _state.update { it.copy(status = Status.Connected, via = "Internet", joinError = null, problem = null) } }
        InternetLink.onRefused = { error, _ -> _state.update { it.copy(status = Status.Idle, via = "", joinError = error) } }
        InternetLink.onGaveUp = { reason -> _state.update { it.copy(status = Status.Idle, via = "", problem = reason) } }
    }

    /** Where the Mac is over the internet, if the home link has told us everything that needs. */
    private fun internetHost(pairing: Pairing): String? =
        if (pairing.macKey == null) null else pairing.rendezvous?.let { Uri.parse(it).host }

    /** Before connecting: home connects by itself, internet waits to be asked. */
    private fun waiting(mode: Mode) = if (mode == Mode.Home) Status.Connecting else Status.Idle

    val pairing: Pairing? get() = store.load()

    /** Whether the phone can try getting back in over the internet without the code. */
    val hasTicket: Boolean get() = InternetLink.hasTicket

    fun pair(pairing: Pairing) {
        InternetLink.disconnect()
        InternetLink.forgetTicket()
        store.save(pairing)
        stop()
        _state.value = State(waiting(state.value.mode), pairing.macName, mode = state.value.mode)
        start()
    }

    fun setMode(mode: Mode) {
        if (mode == state.value.mode) return
        prefs.edit().putString("mode", mode.name).apply()
        stop()
        InternetLink.disconnect()
        _state.update { State(if (it.status == Status.Unpaired) Status.Unpaired else waiting(mode), it.macName, mode = mode, internet = it.internet) }
        start()
    }

    /**
     * Internet mode: connects with the join code the owner just typed, or with no code on the
     * ticket from last time, until [disconnectInternet].
     */
    fun connectInternet(code: String?) {
        val pairing = store.load() ?: return
        val key = pairing.macKey?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() } ?: return
        val server = pairing.rendezvous ?: return
        if (state.value.mode != Mode.Internet || (code == null && !hasTicket)) return
        stop()
        _state.update { it.copy(status = Status.Connecting, joinError = null, problem = null) }
        InternetLink.connect(InternetLink.Mac(key, server, pairing.macName), code)
    }

    /** After the internet connection gave up: try again with what got us in last time. */
    fun retryInternet() {
        _state.update { it.copy(status = Status.Connecting, problem = null) }
        InternetLink.retry()
    }

    fun disconnectInternet() {
        if (state.value.mode != Mode.Internet) return
        InternetLink.disconnect()
        _state.update { if (it.status == Status.Unpaired) it else it.copy(status = Status.Idle, via = "") }
    }

    fun forget() {
        stop()
        InternetLink.disconnect()
        InternetLink.forgetTicket()
        store.clear()
        _state.value = State()
    }

    /** Starts (or keeps) the home reconnect loop. Called by [LinkService]. */
    fun start() {
        if (loop?.isActive == true || store.load() == null || state.value.mode != Mode.Home) return
        loop = scope.launch { connectLoop() }
    }

    fun stop() {
        loop?.cancel()
        loop = null
        socket?.cancel()
        socket = null
    }

    fun send(message: JSONObject): Boolean =
        if (state.value.mode == Mode.Internet) InternetLink.send(message.toString()) else socket?.send(message.toString()) ?: false

    /** A binary message, e.g. microphone audio (see [PhoneMic]). */
    fun sendBytes(bytes: ByteArray): Boolean =
        if (state.value.mode == Mode.Internet) InternetLink.sendBytes(bytes) else socket?.send(bytes.toByteString()) ?: false

    // MARK: connection

    private suspend fun connectLoop() {
        var backoffMs = 1_000L
        while (scope.isActive) {
            val pairing = store.load() ?: return
            val client = pinnedClient(pairing.fingerprint)
            var connected = false
            for ((host, via) in listOf(pairing.host to "Wi-Fi", "127.0.0.1" to "USB")) {
                _state.update { it.copy(status = Status.Connecting, macName = pairing.macName) }
                if (connectAndWait(client, pairing, host, pairing.port, via)) { connected = true; break }
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

    /** What internet connections need, as the Mac tells us at home: its key and its server. */
    private fun rememberInternet(message: JSONObject) {
        val pairing = store.load() ?: return
        val key = message.optString("key").takeIf { it.isNotEmpty() } ?: pairing.macKey
        val server = if (message.has("rendezvous") && !message.isNull("rendezvous")) message.optString("rendezvous") else pairing.rendezvous
        val updated = pairing.copy(macKey = key, rendezvous = server)
        if (updated != pairing) store.save(updated)
        _state.update { it.copy(internet = internetHost(updated)) }
    }

    /** Opens one home connection and suspends until it closes. Returns true if it ever opened. */
    private suspend fun connectAndWait(client: OkHttpClient, pairing: Pairing, host: String, port: Int, via: String): Boolean =
        suspendCancellableCoroutine { continuation ->
            var opened = false
            val request = Request.Builder()
                .url("wss://$host:$port/")
                .header("Authorization", "Bearer ${pairing.token}")
                .build()
            val ws = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send(JSONObject().put("type", "hello").put("device", deviceName).toString())
                    // So the Mac knows this phone when it connects over the internet later.
                    webSocket.send(JSONObject().put("type", "phone-key")
                        .put("key", Base64.encodeToString(DeviceKey.publicKey, Base64.NO_WRAP)).toString())
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    scope.launch {
                        val message = runCatching { JSONObject(text) }.getOrNull() ?: return@launch
                        when (val type = message.optString("type")) {
                            "hello" -> {
                                _state.update { it.copy(macName = message.optString("mac", it.macName)) }
                                rememberInternet(message)
                                opened = true
                                socket = webSocket
                                _state.update { it.copy(status = Status.Connected, via = via) }
                                Remote.onConnected()
                            }
                            "internet" -> rememberInternet(message)
                            else -> Remote.handle(type, message)
                        }
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
                        if (state.value.mode == Mode.Home) Remote.onDisconnected()
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
