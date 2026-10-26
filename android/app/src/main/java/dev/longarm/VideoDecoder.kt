package dev.longarm

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * The phone's hardware H.264 decoder for the cast, drawing straight onto the cast view's surface.
 * Everything runs on its own thread. A decoder starts from a key frame; whenever it can't go on
 * (new surface, a frame missing, an error), it asks the Mac for one through [needKeyFrame].
 */
class VideoDecoder(
    private val currentGeneration: () -> Long,
    private val onRendered: (Long) -> Unit,
    private val needKeyFrame: () -> Unit,
) {
    class Frame(val generation: Long, val keyFrame: Boolean, val width: Int, val height: Int, val bytes: ByteArray, val offset: Int)

    private val handler = Handler(HandlerThread("cast-decoder").apply { start() }.looper)
    private var texture: SurfaceTexture? = null
    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var size = 0 to 0
    private val inputs = ArrayDeque<Int>()     // input buffers the codec has free
    private val pending = ArrayDeque<Frame>()  // frames waiting for one
    private var count = 0L

    /**
     * The cast view's texture to draw on, or null when it goes away. Released here, after the
     * decoder that draws on it, so nothing draws on a dead surface.
     */
    fun setTexture(texture: SurfaceTexture?) {
        handler.post {
            release()
            surface?.release()
            this.texture?.takeIf { it !== texture }?.release()
            this.texture = texture
            surface = texture?.let(::Surface)
            if (surface != null) needKeyFrame()
        }
    }

    fun submit(frame: Frame) {
        handler.post {
            if (surface == null) return@post
            if (codec == null || size != frame.width to frame.height) {
                if (!frame.keyFrame) return@post   // nothing to build on until a key frame comes
                if (!start(frame)) return@post
            }
            pending.addLast(frame)
            if (pending.size > MAX_PENDING) {   // the decoder stopped taking frames: start over
                Log.i(TAG, "decoder fell behind, restarting")
                release()
                needKeyFrame()
                return@post
            }
            feed()
        }
    }

    private fun start(frame: Frame): Boolean {
        release()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, frame.width, frame.height).apply {
            // The SPS and PPS at the front of a key frame are the decoder's setup data.
            parameterSets(frame).forEachIndexed { i, set -> setByteBuffer("csd-$i", ByteBuffer.wrap(set)) }
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)   // real time
        }
        return try {
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                    if (c !== this@VideoDecoder.codec) return
                    inputs.addLast(index)
                    feed()
                }

                override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    if (c !== this@VideoDecoder.codec) return
                    val generation = info.presentationTimeUs shr 32
                    val show = generation == currentGeneration()   // a late frame of the previous area isn't shown
                    runCatching { c.releaseOutputBuffer(index, show) }
                    if (show) onRendered(generation)
                }

                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                    if (c !== this@VideoDecoder.codec) return
                    Log.i(TAG, "decoder error: ${e.diagnosticInfo}")
                    release()
                    needKeyFrame()
                }

                override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
            }, handler)
            codec.configure(format, surface, null, 0)
            codec.start()
            this.codec = codec
            size = frame.width to frame.height
            Log.i(TAG, "decoder started: ${codec.name} ${frame.width}x${frame.height}")
            true
        } catch (e: Exception) {
            Log.i(TAG, "decoder failed to start: $e")
            release()
            false
        }
    }

    private fun feed() {
        val codec = codec ?: return
        while (inputs.isNotEmpty() && pending.isNotEmpty()) {
            val index = inputs.removeFirst()
            val frame = pending.removeFirst()
            try {
                val buffer = codec.getInputBuffer(index) ?: continue
                buffer.clear()
                buffer.put(frame.bytes, frame.offset, frame.bytes.size - frame.offset)
                // The time carries the generation, so the output side knows which area a frame shows.
                codec.queueInputBuffer(index, 0, frame.bytes.size - frame.offset, (frame.generation shl 32) or (count++ and 0xFFFFFFFFL), 0)
            } catch (e: IllegalStateException) {
                Log.i(TAG, "decoder stopped taking frames: $e")
                release()
                needKeyFrame()
                return
            }
        }
    }

    private fun release() {
        codec?.let { runCatching { it.stop() }; runCatching { it.release() } }
        codec = null
        size = 0 to 0
        inputs.clear()
        pending.clear()
    }

    /** The NAL units before the first picture in a key frame (SPS, PPS), each with its start code. */
    private fun parameterSets(frame: Frame): List<ByteArray> {
        val bytes = frame.bytes
        val starts = (frame.offset until bytes.size - 3).filter {
            bytes[it] == 0.toByte() && bytes[it + 1] == 0.toByte() && bytes[it + 2] == 0.toByte() && bytes[it + 3] == 1.toByte()
        }
        val sets = mutableListOf<ByteArray>()
        for ((i, start) in starts.withIndex()) {
            val type = bytes[start + 4].toInt() and 0x1F
            if (type != 7 && type != 8) break   // 7 = SPS, 8 = PPS
            sets += bytes.copyOfRange(start, starts.getOrElse(i + 1) { bytes.size })
        }
        return sets
    }

    companion object {
        private const val TAG = "Longarm"
        private const val MAX_PENDING = 30
    }
}
