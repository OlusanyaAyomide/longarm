package dev.longarm

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
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
 * remote control messages one way and the screen's video the other (see [Remote]).
 *
 * The owner picks how it connects ([Mode]); it never falls back from one to the other:
 * - Home: always on, reconnecting by itself: the last known address, then USB (adb reverse →
 *   localhost), then Bonjour.
 * - Internet: to the Mac's Tailscale address, only while remote control is open, and only with
 *   the join code set on the Mac. The right code earns a ticket from the Mac (kept encrypted, see
 *   [SecretStore]), which lets the phone back in without the code until it goes 10 minutes unused.
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
        /** The Mac's Tailscale address, once known: needed for [Mode.Internet]. */
        val internet: String? = null,
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
    private lateinit var secrets: SecretStore
    private var joinCode: String? = null   // internet only: just typed, until the Mac swaps it for a ticket

    fun init(context: Context) {
        store = PairingStore(context)
        discovery = Discovery(context)
        prefs = context.getSharedPreferences("link", Context.MODE_PRIVATE)
        secrets = SecretStore(context)
        deviceName = Settings.Global.getString(context.contentResolver, "device_name") ?: Build.MODEL
        val mode = runCatching { Mode.valueOf(prefs.getString("mode", null) ?: "") }.getOrDefault(Mode.Home)
        store.load()?.let { p -> _state.value = State(waiting(mode), p.macName, mode = mode, internet = p.internetHost) }
    }

    /** Before connecting: home connects by itself, internet waits to be asked. */
    private fun waiting(mode: Mode) = if (mode == Mode.Home) Status.Connecting else Status.Idle

    val pairing: Pairing? get() = store.load()

    /** Whether the phone can try getting back in over the internet without the code. */
    val hasTicket: Boolean get() = secrets[TICKET] != null

    fun pair(pairing: Pairing) {
        secrets[TICKET] = null
        store.save(pairing)
        stop()
        _state.value = State(waiting(state.value.mode), pairing.macName, mode = state.value.mode, internet = pairing.internetHost)
        start()
    }

    fun setMode(mode: Mode) {
        if (mode == state.value.mode) return
        prefs.edit().putString("mode", mode.name).apply()
        stop()
        joinCode = null
        _state.update { State(if (it.status == Status.Unpaired) Status.Unpaired else waiting(mode), it.macName, mode = mode, internet = it.internet) }
        start()
    }

    /**
     * Internet mode: connects with the join code the owner just typed, or with no code on the
     * ticket from last time, until [disconnectInternet].
     */
    fun connectInternet(code: String?) {
        if (state.value.mode != Mode.Internet || store.load()?.internetHost == null || (code == null && !hasTicket)) return
        stop()
        joinCode = code
        _state.update { it.copy(status = Status.Connecting, joinError = null) }
        loop = scope.launch { internetLoop() }
    }

    fun disconnectInternet() {
        if (state.value.mode != Mode.Internet) return
        stop()
        joinCode = null
        _state.update { if (it.status == Status.Unpaired) it else it.copy(status = Status.Idle, via = "") }
    }

    fun forget() {
        stop()
        secrets[TICKET] = null
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
                if (connectAndWait(client, pairing, host, pairing.port, via) != Outcome.Failed) { connected = true; break }
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

    /** Over Tailscale, retrying while the session lasts; a refused code ends it. */
    private suspend fun internetLoop() {
        var backoffMs = 1_000L
        while (scope.isActive) {
            val pairing = store.load() ?: return
            val host = pairing.internetHost ?: return
            val port = pairing.internetPort ?: return
            _state.update { it.copy(status = Status.Connecting) }
            when (connectAndWait(pinnedClient(pairing.fingerprint), pairing, host, port, "Internet")) {
                Outcome.Refused -> {
                    joinCode = null
                    _state.update { it.copy(status = Status.Idle, via = "") }
                    return
                }
                Outcome.Joined -> backoffMs = 1_000L
                Outcome.Failed -> {
                    delay(backoffMs)
                    backoffMs = (backoffMs * 2).coerceAtMost(8_000L)
                }
            }
        }
    }

    private enum class Outcome { Failed, Joined, Refused }

    private fun connected(webSocket: WebSocket, via: String) {
        socket = webSocket
        _state.update { it.copy(status = Status.Connected, via = via, joinError = null) }
        Remote.onConnected()
    }

    /** The Mac's Tailscale address, as it tells us (when its internet connections are on). */
    private fun rememberInternet(address: JSONObject?) {
        val host = address?.optString("host")?.takeIf { it.isNotEmpty() } ?: return
        val pairing = store.load() ?: return
        val port = address.optInt("port").takeIf { it > 0 }
        if (host != pairing.internetHost || port != pairing.internetPort) store.save(pairing.copy(internetHost = host, internetPort = port))
        _state.update { it.copy(internet = host) }
    }

    /** Opens one connection and suspends until it closes: whether it got in, failed, or the Mac refused the code. */
    private suspend fun connectAndWait(client: OkHttpClient, pairing: Pairing, host: String, port: Int, via: String): Outcome =
        suspendCancellableCoroutine { continuation ->
            var outcome = Outcome.Failed
            val request = Request.Builder()
                .url("wss://$host:$port/")
                .header("Authorization", "Bearer ${pairing.token}")
                .build()
            val ws = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send(JSONObject().put("type", "hello").put("device", deviceName).toString())
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    scope.launch {
                        val message = runCatching { JSONObject(text) }.getOrNull() ?: return@launch
                        when (val type = message.optString("type")) {
                            "hello" -> {
                                _state.update { it.copy(macName = message.optString("mac", it.macName)) }
                                rememberInternet(message.optJSONObject("internet"))
                                if (!message.optBoolean("needsCode")) {
                                    outcome = Outcome.Joined
                                    connected(webSocket, via)
                                } else {
                                    val join = JSONObject().put("type", "join")
                                    joinCode?.let { join.put("code", it) } ?: join.put("ticket", secrets[TICKET] ?: "")
                                    webSocket.send(join.toString())
                                }
                            }
                            "join" -> if (message.optBoolean("ok")) {
                                outcome = Outcome.Joined
                                secrets[TICKET] = message.optString("ticket").takeIf { it.isNotEmpty() }
                                joinCode = null
                                connected(webSocket, via)
                            } else {
                                outcome = Outcome.Refused
                                if (message.optBoolean("needsCode")) secrets[TICKET] = null
                                _state.update { it.copy(joinError = message.optString("error", "The Mac didn't let this phone in")) }
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
                        Remote.onDisconnected()
                        if (continuation.isActive) continuation.resume(outcome)
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

    private const val TICKET = "joinTicket"
}
