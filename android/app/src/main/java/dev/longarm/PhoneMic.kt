package dev.longarm

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/**
 * The phone's microphone, for dictating on the Mac during remote control: 16 kHz mono 16-bit PCM
 * in 100 ms chunks, each sent to the Mac as a binary message (0x03, then the PCM), where the same
 * speech-to-text engine as Right Option turns it into text. Reads on its own thread.
 */
object PhoneMic {
    private const val RATE = 16_000
    private const val CHUNK = 3_200   // 100 ms of 16-bit mono at 16 kHz

    @Volatile private var running = false

    /** Needs the RECORD_AUDIO permission; returns false if the microphone can't be opened. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (running) return true
        val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = runCatching {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, CHUNK * 4))
        }.getOrNull() ?: return false
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        running = true
        Thread({
            val buffer = ByteArray(1 + CHUNK).also { it[0] = 3 }
            try {
                record.startRecording()
                while (running) {
                    var read = 0
                    while (read < CHUNK && running) {
                        val count = record.read(buffer, 1 + read, CHUNK - read)
                        if (count <= 0) break
                        read += count
                    }
                    if (read > 0) MacLink.sendBytes(buffer.copyOf(1 + read))
                }
            } finally {
                runCatching { record.stop() }
                record.release()
            }
        }, "phone-mic").start()
        return true
    }

    fun stop() {
        running = false
    }
}
