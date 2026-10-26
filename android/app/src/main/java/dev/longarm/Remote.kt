package dev.longarm

import android.content.Context
import android.content.SharedPreferences
import android.graphics.SurfaceTexture
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * Remote control from the phone's side: asks the Mac to start (it has to be allowed in the Mac's
 * menu), shows its screen (H.264 from the Mac, decoded by [VideoDecoder]) and sends taps, keys and
 * dictation back. The messages are listed in RemoteControl.swift on the Mac.
 *
 * Runs on the main thread, except video frames, which arrive on OkHttp's thread and go straight
 * to the decoder's.
 */
object Remote {
    /** The Mac's screen as it's being shown. */
    data class Screen(val id: String, val name: String, val width: Int, val height: Int)

    /** As the Mac reports it: allowed from its menu, and on while the phone is in control. */
    data class State(val on: Boolean = false, val allowed: Boolean = false, val error: String? = null)

    /**
     * Dictating from the phone's microphone into the keyboard: [text] is what's been recognised
     * (kept until typed on the Mac with ↵, or discarded), [live] the words still being worked out.
     */
    data class Dictation(val on: Boolean = false, val text: String = "", val live: String = "") {
        val shown: String get() = listOf(text, live).filter { it.isNotEmpty() }.joinToString(" ")
    }

    private lateinit var prefs: SharedPreferences

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private val _screen = MutableStateFlow<Screen?>(null)
    val screen: StateFlow<Screen?> = _screen.asStateFlow()

    /** Whether the picture on screen is of [screen] yet (until then: "Waiting for the picture…"). */
    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready.asStateFlow()

    private val _dictation = MutableStateFlow(Dictation())
    val dictation: StateFlow<Dictation> = _dictation.asStateFlow()

    /** What's stopping the picture, from the Mac (e.g. no Screen Recording permission), until it shows. */
    private val _problem = MutableStateFlow<String?>(null)
    val problem: StateFlow<String?> = _problem.asStateFlow()

    /** Short messages for the user (errors from the Mac and the like). */
    private val _notices = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val notices: SharedFlow<String> = _notices.asSharedFlow()

    private var wanted = false               // the remote screen is open
    private var skipNextPhrase = false       // its words were already typed with ↵ while still in progress
    @Volatile private var generation = -1L   // which screen change frames must belong to
    @Volatile private var keyFrameAskedAt = 0L

    private val decoder = VideoDecoder(
        currentGeneration = { generation },
        onRendered = { rendered ->
            stats.rendered++
            if (rendered == generation && !_ready.value) {
                _ready.value = true
                _problem.value = null
            }
        },
        needKeyFrame = ::requestKeyFrame,
    )

    fun init(context: Context) {
        prefs = context.getSharedPreferences("remote", Context.MODE_PRIVATE)
    }

    fun notice(text: String) {
        _notices.tryEmit(text)
    }

    // MARK: settings, remembered

    /** Opens sideways (a Mac screen fits a landscape phone far better); ⟳ changes it. */
    var landscape: Boolean
        get() = prefs.getBoolean("landscape", true)
        set(value) = prefs.edit().putBoolean("landscape", value).apply()

    /** The keyboard: how far it's dragged up from the bottom (dp), and its blur, 0…1. */
    var keyboardLift: Float
        get() = prefs.getFloat("keyboardLift", 0f)
        set(value) = prefs.edit().putFloat("keyboardLift", value).apply()
    var keyboardBlur: Float
        get() = prefs.getFloat("keyboardBlur", 0.5f)
        set(value) = prefs.edit().putFloat("keyboardBlur", value).apply()

    // MARK: control

    /** The remote screen opened (true) or closed. */
    fun setWanted(on: Boolean) {
        if (!on) stopDictation()
        wanted = on
        MacLink.send(JSONObject().put("type", "remote").put("on", on))
        if (!on) show(null, -1)
    }

    fun click(x: Float, y: Float, right: Boolean = false, count: Int = 1) = sendPointer("click", x, y) {
        put("button", if (right) "right" else "left").put("count", count)
    }

    fun drag(action: String, x: Float, y: Float) = sendPointer("drag-$action", x, y) {}

    fun scroll(x: Float, y: Float, dx: Float, dy: Float) {
        MacLink.send(JSONObject().put("type", "scroll").put("x", x.toDouble()).put("y", y.toDouble())
            .put("dx", dx.toDouble()).put("dy", dy.toDouble()))
    }

    fun type(text: String) {
        MacLink.send(JSONObject().put("type", "type").put("text", text))
    }

    /** [key] is a name the Mac knows ("return", "left", "tab", "c", "+", …); [modifiers]: cmd, shift, option, control. */
    fun key(key: String, modifiers: Collection<String> = emptyList()) {
        MacLink.send(JSONObject().put("type", "key").put("key", key).put("modifiers", JSONArray(modifiers)))
    }

    private fun sendPointer(action: String, x: Float, y: Float, extra: JSONObject.() -> Unit) {
        MacLink.send(JSONObject().put("type", "pointer").put("action", action)
            .put("x", x.toDouble()).put("y", y.toDouble()).apply(extra))
    }

    // MARK: dictation

    /** Needs the microphone permission. */
    fun startDictation() {
        if (_dictation.value.on) return
        if (!PhoneMic.start()) return notice("Couldn't open the phone's microphone")
        MacLink.send(JSONObject().put("type", "dictate").put("on", true))
        _dictation.value = _dictation.value.copy(on = true)
    }

    fun stopDictation() {
        if (!_dictation.value.on) return
        PhoneMic.stop()
        MacLink.send(JSONObject().put("type", "dictate").put("on", false))
        _dictation.value = _dictation.value.copy(on = false)
    }

    /** The dictated words, now being typed on the Mac; listening goes on. */
    fun takeDictation(): String {
        val words = _dictation.value.shown
        skipNextPhrase = _dictation.value.live.isNotEmpty()
        _dictation.value = _dictation.value.copy(text = "", live = "")
        return words
    }

    fun discardDictation() {
        skipNextPhrase = _dictation.value.live.isNotEmpty()
        _dictation.value = _dictation.value.copy(text = "", live = "")
    }

    /** ⌫ on dictated words: takes back the last character. */
    fun backspaceDictation() {
        _dictation.value = _dictation.value.let { it.copy(text = it.text.dropLast(1)) }
    }

    // MARK: video

    /** The screen view's texture, which the decoder draws on (null when it goes away). */
    fun setTexture(texture: SurfaceTexture?) = decoder.setTexture(texture)

    private fun requestKeyFrame() {
        val now = SystemClock.elapsedRealtime()
        if (now - keyFrameAskedAt < 300) return   // one is on its way
        keyFrameAskedAt = now
        MacLink.send(JSONObject().put("type", "keyframe"))
    }

    /**
     * A binary message from the Mac (OkHttp's thread): 0x02, the generation (UInt32), 1 for a key
     * frame else 0, width and height (UInt16 each), then the H.264 frame; numbers big-endian.
     */
    fun onFrame(bytes: ByteArray) {
        if (bytes.size < 11 || bytes[0] != 2.toByte()) return
        fun number(at: Int, length: Int) = (at until at + length).fold(0L) { value, i -> value shl 8 or (bytes[i].toLong() and 0xFF) }
        val frameGeneration = number(1, 4)
        if (frameGeneration != generation) return
        decoder.submit(VideoDecoder.Frame(frameGeneration, bytes[5] == 1.toByte(), number(6, 2).toInt(), number(8, 2).toInt(), bytes, 10))
        stats.received++
        stats.bytes += bytes.size
        logStats()
    }

    private class Stats(var since: Long = SystemClock.elapsedRealtime(), var received: Int = 0, var bytes: Long = 0, @Volatile var rendered: Int = 0)
    private var stats = Stats()

    /** Every 5 s while frames arrive: `adb logcat -s Longarm:I`. */
    private fun logStats() {
        val elapsed = SystemClock.elapsedRealtime() - stats.since
        if (elapsed < 5000) return
        Log.i("Longarm", "frames: %.1f/s received, %.1f/s shown, %.1f KB each".format(
            stats.received * 1000.0 / elapsed, stats.rendered * 1000.0 / elapsed, stats.bytes / 1024.0 / stats.received))
        stats = Stats()
    }

    private fun show(screen: Screen?, generation: Long) {
        if (generation != this.generation) _ready.value = false
        this.generation = generation
        _screen.value = screen
    }

    // MARK: the link

    fun onConnected() {
        if (wanted) setWanted(true)
    }

    fun onDisconnected() {
        PhoneMic.stop()
        _dictation.value = Dictation()
        show(null, -1)
    }

    fun handle(type: String, message: JSONObject) {
        val error = message.optString("error").takeIf { it.isNotEmpty() && !message.isNull("error") }
        when (type) {
            "state" -> {
                val wasAllowed = _state.value.allowed
                _state.value = State(message.optBoolean("on"), message.optBoolean("allowed"), error)
                if (!_state.value.on && _dictation.value.on) {   // stopped on the Mac: so is dictation
                    PhoneMic.stop()
                    _dictation.value = Dictation()
                }
                if (error != null && wanted) notice(error)
                // Allowed on the Mac while the remote screen waited: ask again.
                if (wanted && !wasAllowed && _state.value.allowed && !_state.value.on) setWanted(true)
            }
            "screen" -> {
                val region = message.optJSONObject("region")
                if (region == null || !wanted) {
                    show(null, -1)
                } else {
                    show(Screen(region.optString("id"), region.optString("name"), region.optInt("width"), region.optInt("height")),
                        message.optLong("generation", -1))
                }
            }
            "dictation" -> {
                val current = _dictation.value
                when {
                    error != null -> {
                        PhoneMic.stop()
                        _dictation.value = current.copy(on = false, live = "")
                        notice(error)
                    }
                    message.has("final") -> {
                        val phrase = message.optString("final")
                        if (skipNextPhrase) skipNextPhrase = false
                        else _dictation.value = current.copy(text = listOf(current.text, phrase).filter { it.isNotEmpty() }.joinToString(" "), live = "")
                    }
                    message.optBoolean("done") -> _dictation.value = current.copy(live = "")
                    else -> _dictation.value = current.copy(live = message.optString("text"))
                }
            }
            "notice" -> {
                notice(message.optString("text"))
                if (wanted && !_ready.value) _problem.value = message.optString("text")
            }
        }
    }
}
