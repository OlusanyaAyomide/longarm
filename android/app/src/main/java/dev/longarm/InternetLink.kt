package dev.longarm

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

/**
 * Over the internet: a WebRTC connection to the Mac, set up through the rendezvous server
 * (server/ in the repository) with offers signed by this phone's [DeviceKey] and answers checked
 * against the Mac's key from pairing ([SignedSignal]). It's direct when the two networks allow it,
 * otherwise through the relay; end-to-end encrypted either way. The screen arrives as a video
 * track, drawn on the remote view's texture; the same messages as the home link go over a data
 * channel, once the Mac lets the phone in with the join code or the ticket from last time.
 *
 * When the connection drops it tries, in turn: waiting a moment, an ICE restart (new paths, same
 * session), then a fresh connection on the ticket. While the Mac isn't signed in to the server it
 * retries every 10 s, for 2 minutes. Everything here runs on the main thread.
 */
object InternetLink {
    /** The Mac to reach, from pairing and the home link. */
    data class Mac(val key: ByteArray, val rendezvous: String, val name: String) {
        val id: String get() = DeviceKey.idOf(key)
    }

    /** Status changes for [MacLink]: connecting (or reconnecting), in, refused, or given up. */
    var onConnecting: () -> Unit = {}
    var onJoined: () -> Unit = {}
    var onRefused: (error: String, needsCode: Boolean) -> Unit = { _, _ -> }
    var onGaveUp: (reason: String) -> Unit = {}

    private const val TAG = "Longarm"
    private const val TICKET = "joinTicket"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var secrets: SecretStore
    private lateinit var deviceName: String
    private lateinit var context: Context
    private val http = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS).build()

    private val eglBase by lazy { EglBase.create() }
    private val factory by lazy {
        // Loaded on first use, not at launch: most of the time the phone connects at home.
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        PeerConnectionFactory.builder()
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .createPeerConnectionFactory()
    }
    private val renderer by lazy { EglRenderer("screen").apply { init(eglBase.eglBaseContext, EglBase.CONFIG_PLAIN, GlRectDrawer()) } }
    private var texture: SurfaceTexture? = null

    private var mac: Mac? = null
    private var code: String? = null   // just typed: swapped for a ticket once the Mac lets us in
    private var active = false

    private var rendezvous: WebSocket? = null
    private var signedIn = false
    private var iceServers = listOf(PeerConnection.IceServer.builder(listOf("stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302")).createIceServer())
    private var relay: PeerConnection.IceServer? = null

    private var connection: PeerConnection? = null
    private var channel: DataChannel? = null
    private var session = ""
    private var hasAnswer = false
    private val pendingCandidates = mutableListOf<IceCandidate>()
    private var joined = false
    private var everJoined = false
    private var connected = false
    private var ladder: Job? = null
    private var offlineSince = 0L
    private var backoffMs = 1_000L
    private var serverFailures = 0   // in a row, before ever signing in this time

    fun init(context: Context, deviceName: String) {
        this.context = context.applicationContext
        secrets = SecretStore(context)
        this.deviceName = deviceName
    }

    val hasTicket: Boolean get() = secrets[TICKET] != null

    fun forgetTicket() {
        secrets[TICKET] = null
    }

    /** Connects with the code just typed, or with null on the ticket from last time. */
    fun connect(mac: Mac, code: String?) {
        disconnect()
        this.mac = mac
        this.code = code
        active = true
        everJoined = false
        offlineSince = 0
        serverFailures = 0
        backoffMs = 1_000
        onConnecting()
        openRendezvous()
    }

    /** Tries again after giving up (the Mac was offline), with whatever got us in last time. */
    fun retry() {
        val mac = mac ?: return
        connect(mac, code)
    }

    fun disconnect() {
        if (!active) return
        active = false
        signal(JSONObject().put("kind", "bye"))
        closeSession()
        rendezvous?.close(1000, null)
        rendezvous = null
        signedIn = false
        Remote.onDisconnected()
    }

    fun send(text: String): Boolean = channel?.takeIf { joined }?.send(DataChannel.Buffer(ByteBuffer.wrap(text.toByteArray()), false)) ?: false

    fun sendBytes(bytes: ByteArray): Boolean = channel?.takeIf { joined }?.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), true)) ?: false

    /** The phone switched networks: look for new paths at once rather than waiting to notice. */
    fun networkChanged() {
        if (active && connection != null) scope.launch { delay(500); restartIce() }
    }

    // MARK: the picture

    /** The remote view's texture, which the video is drawn on; this releases it when done. */
    fun setTexture(texture: SurfaceTexture?) {
        val old = this.texture
        this.texture = texture
        if (old != null) renderer.releaseEglSurface { old.release() }
        if (texture != null) renderer.createEglSurface(texture)
    }

    private val sink = VideoSink { frame ->
        renderer.onFrame(frame)
        if (!Remote.ready.value) scope.launch { Remote.onPictureShown() }
    }

    // MARK: the rendezvous server

    private fun openRendezvous() {
        val mac = mac ?: return
        val request = runCatching { Request.Builder().url(mac.rendezvous).build() }.getOrNull()
            ?: return giveUp("The Mac's internet server address isn't valid")
        rendezvous = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                scope.launch {
                    if (webSocket !== rendezvous) return@launch
                    runCatching { JSONObject(text) }.getOrNull()?.let(::fromServer)
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = lost(webSocket)
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = lost(webSocket)
        })
    }

    private fun lost(webSocket: WebSocket) {
        scope.launch {
            if (webSocket !== rendezvous || !active) return@launch
            rendezvous = null
            val wasSignedIn = signedIn
            signedIn = false
            // Never reached it this time (a wrong or old address, no internet): say so rather than
            // trying forever. Once in, a lost server is retried for as long as the session lasts.
            if (!wasSignedIn && !everJoined && ++serverFailures >= 4) {
                val host = mac?.rendezvous?.let { runCatching { java.net.URI(it).host }.getOrNull() } ?: "the internet server"
                return@launch giveUp("Can't reach $host. Is the phone online? If the Mac's internet server changed, connect at home once so this phone learns it.")
            }
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(8_000)
            if (active && rendezvous == null) openRendezvous()
        }
    }

    private fun fromServer(message: JSONObject) {
        when (message.optString("type")) {
            "challenge" -> {
                val signature = DeviceKey.sign("longarm-rendezvous-v1\n${message.optString("nonce")}\nphone".toByteArray())
                rendezvous?.send(JSONObject().put("type", "hello").put("role", "phone")
                    .put("key", Base64.encodeToString(DeviceKey.publicKey, Base64.NO_WRAP))
                    .put("sig", Base64.encodeToString(signature, Base64.NO_WRAP)).toString())
            }
            "ready" -> {
                signedIn = true
                serverFailures = 0
                backoffMs = 1_000
                readRelay(message.optJSONObject("turn"))
                // A session that's still up only needs new paths; otherwise start one.
                if (connection == null) startSession() else restartIce()
            }
            "turn" -> readRelay(message.optJSONObject("turn"))
            "signal" -> {
                val mac = mac ?: return
                val data = message.optJSONObject("data") ?: return
                if (message.optString("from") != mac.id) return
                SignedSignal.open(data, from = mac.id, me = DeviceKey.id, publicKey = mac.key)?.let(::fromMac)
                    ?: Log.w(TAG, "internet: ignored a signal the Mac didn't sign")
            }
            "error" -> if (message.optString("code") == "unreachable") macOffline()
        }
    }

    private fun readRelay(turn: JSONObject?) {
        turn ?: return
        val urls = turn.optJSONArray("urls") ?: return
        relay = PeerConnection.IceServer.builder((0 until urls.length()).map(urls::getString))
            .setUsername(turn.optString("username")).setPassword(turn.optString("credential")).createIceServer()
    }

    /** The Mac isn't signed in (asleep, Longarm quit, Internet off): keep checking for a while. */
    private fun macOffline() {
        if (joined) return
        if (offlineSince == 0L) offlineSince = System.currentTimeMillis()
        closeSession()
        if (System.currentTimeMillis() - offlineSince > 2 * 60_000) {
            return giveUp("${mac?.name ?: "The Mac"} is offline. Is Longarm running there, with Internet on?")
        }
        onConnecting()
        ladder?.cancel()
        ladder = scope.launch {
            delay(10_000)
            if (active && signedIn) startSession()
        }
    }

    private fun giveUp(reason: String) {
        disconnect()
        onGaveUp(reason)
    }

    private fun signal(fields: JSONObject) {
        val mac = mac ?: return
        if (!signedIn || session.isEmpty()) return
        val sealed = SignedSignal.seal(fields.put("session", session), from = DeviceKey.id, to = mac.id)
        rendezvous?.send(JSONObject().put("type", "signal").put("to", mac.id).put("data", sealed).toString())
    }

    // MARK: the WebRTC session

    private fun startSession() {
        closeSession()
        session = ByteArray(12).also(SecureRandom()::nextBytes).let { Base64.encodeToString(it, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }
        val config = PeerConnection.RTCConfiguration(iceServers + listOfNotNull(relay)).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
        val pc = factory.createPeerConnection(config, Observer(session)) ?: return giveUp("Couldn't start WebRTC")
        pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY))
        val channel = pc.createDataChannel("longarm", DataChannel.Init().apply { ordered = true })
        channel.registerObserver(ChannelObserver(channel))
        connection = pc
        this.channel = channel
        offer()
        // No way in after a while (no answer, no join): start over, a little later each time.
        ladder?.cancel()
        ladder = scope.launch {
            delay(20_000)
            if (active && !joined) {
                Log.i(TAG, "internet: no connection after 20 s, starting over")
                delay(backoffMs)
                backoffMs = (backoffMs * 2).coerceAtMost(30_000)
                if (active && signedIn) startSession()
            }
        }
    }

    private fun offer() {
        val pc = connection ?: return
        pc.createOffer(object : SdpAdapter() {
            override fun onCreateSuccess(description: SessionDescription) {
                pc.setLocalDescription(SdpAdapter(), description)
                scope.launch { signal(JSONObject().put("kind", "offer").put("sdp", description.description)) }
            }
        }, MediaConstraints())
    }

    /** New paths for the same session (after the network changed or the old one died). */
    private fun restartIce() {
        val pc = connection ?: return
        if (!signedIn) return   // when the server's back, "ready" calls this again
        Log.i(TAG, "internet: looking for a new path")
        hasAnswer = false
        pc.restartIce()
        offer()
    }

    private fun closeSession() {
        joined = false
        connected = false
        hasAnswer = false
        pendingCandidates.clear()
        channel?.unregisterObserver()
        channel?.close()
        channel = null
        connection?.dispose()
        connection = null
    }

    private fun fromMac(fields: JSONObject) {
        if (fields.optString("session") != session) return
        val pc = connection ?: return
        when (fields.optString("kind")) {
            "answer" -> pc.setRemoteDescription(object : SdpAdapter() {
                override fun onSetSuccess() {
                    scope.launch {
                        hasAnswer = true
                        pendingCandidates.forEach(pc::addIceCandidate)
                        pendingCandidates.clear()
                    }
                }
            }, SessionDescription(SessionDescription.Type.ANSWER, fields.optString("sdp")))
            "candidate" -> {
                val candidate = IceCandidate(fields.optString("sdpMid"), fields.optInt("sdpMLineIndex"), fields.optString("candidate"))
                if (hasAnswer) pc.addIceCandidate(candidate) else pendingCandidates += candidate
            }
            // The Mac ended it (it waited too long for us, or the join code changed): try a fresh one.
            "bye" -> if (active) {
                closeSession()
                if (everJoined) { onConnecting(); scope.launch { delay(1_000); if (active && signedIn) startSession() } }
                else giveUp("${mac?.name ?: "The Mac"} closed the connection")
            }
        }
    }

    private fun connectionChanged(state: PeerConnection.IceConnectionState) {
        when (state) {
            PeerConnection.IceConnectionState.CONNECTED, PeerConnection.IceConnectionState.COMPLETED -> {
                connected = true
                if (joined) { ladder?.cancel(); onJoined() }
            }
            PeerConnection.IceConnectionState.DISCONNECTED, PeerConnection.IceConnectionState.FAILED -> {
                connected = false
                if (!joined) return
                onConnecting()
                // A moment for a blip to pass, then new paths, then a fresh connection.
                ladder?.cancel()
                ladder = scope.launch {
                    delay(if (state == PeerConnection.IceConnectionState.FAILED) 0 else 2_000)
                    if (connected) return@launch
                    restartIce()
                    delay(8_000)
                    if (!connected && active && signedIn) { Log.i(TAG, "internet: starting a fresh connection"); startSession() }
                }
            }
            else -> {}
        }
    }

    private fun fromChannel(text: String) {
        val message = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (val type = message.optString("type")) {
            "hello" -> {
                channel?.send(DataChannel.Buffer(ByteBuffer.wrap(JSONObject().put("type", "hello").put("device", deviceName).toString().toByteArray()), false))
                val join = JSONObject().put("type", "join")
                code?.let { join.put("code", it) } ?: join.put("ticket", secrets[TICKET] ?: "")
                channel?.send(DataChannel.Buffer(ByteBuffer.wrap(join.toString().toByteArray()), false))
            }
            "join" -> if (message.optBoolean("ok")) {
                joined = true
                everJoined = true
                offlineSince = 0
                backoffMs = 1_000
                ladder?.cancel()
                secrets[TICKET] = message.optString("ticket").takeIf { it.isNotEmpty() }
                code = null
                onJoined()
                Remote.onConnected()
            } else {
                if (message.optBoolean("needsCode")) secrets[TICKET] = null
                val error = message.optString("error", "The Mac didn't let this phone in")
                disconnect()
                onRefused(error, message.optBoolean("needsCode"))
            }
            "path" -> Remote.setPath(relay = message.optBoolean("relay"))
            else -> if (joined) Remote.handle(type, message)
        }
    }

    // MARK: WebRTC callbacks (its own threads), handed to the main thread

    private class Observer(val session: String) : PeerConnection.Observer {
        private fun current(block: () -> Unit) {
            scope.launch { if (session == InternetLink.session) block() }
        }

        override fun onIceCandidate(candidate: IceCandidate) {
            current {
                signal(JSONObject().put("kind", "candidate").put("candidate", candidate.sdp)
                    .put("sdpMid", candidate.sdpMid).put("sdpMLineIndex", candidate.sdpMLineIndex))
            }
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
            current { connectionChanged(state) }
        }

        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent) {
            val relayed = event.local.sdp.contains(" typ relay") || event.remote.sdp.contains(" typ relay")
            current { Remote.setPath(relayed) }
        }

        override fun onTrack(transceiver: RtpTransceiver) {
            (transceiver.receiver.track() as? VideoTrack)?.addSink(sink)
        }

        override fun onSignalingChange(state: PeerConnection.SignalingState) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {}
    }

    private class ChannelObserver(val channel: DataChannel) : DataChannel.Observer {
        override fun onMessage(buffer: DataChannel.Buffer) {
            if (buffer.binary) return
            val bytes = ByteArray(buffer.data.remaining()).also { buffer.data.get(it) }
            scope.launch { if (channel === InternetLink.channel) fromChannel(String(bytes)) }
        }

        override fun onStateChange() {}
        override fun onBufferedAmountChange(previousAmount: Long) {}
    }

    private open class SdpAdapter : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) { Log.w(TAG, "internet: $error") }
        override fun onSetFailure(error: String?) { Log.w(TAG, "internet: $error") }
    }

}
