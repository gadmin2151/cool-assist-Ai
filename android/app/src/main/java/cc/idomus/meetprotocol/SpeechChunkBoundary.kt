package cc.idomus.meetprotocol

import kotlin.math.sqrt

/**
 * Prefer a 400 ms quiet gap after six seconds, but bound live latency at fourteen seconds. This is
 * a segmentation hint, not speech recognition: no quiet samples are discarded.
 */
internal class SpeechChunkBoundary(
    private val sampleRate: Int = WavWriter.SAMPLE_RATE,
    private val minimumSeconds: Int = 6,
    private val quietMilliseconds: Int = 400,
) {
    val frameSamples: Int = (sampleRate / 50).coerceAtLeast(1)
    private var quietSamples = 0L

    init {
        require(sampleRate > 0 && minimumSeconds > 0 && quietMilliseconds > 0)
    }

    fun shouldFinish(samples: ShortArray, offset: Int, count: Int, chunkSamples: Long): Boolean {
        require(count > 0 && offset >= 0 && offset <= samples.size - count)
        var energy = 0.0
        var peak = 0.0
        for (i in offset until offset + count) {
            val sample = samples[i].toDouble() / 32768.0
            energy += sample * sample
            peak = maxOf(peak, kotlin.math.abs(sample))
        }
        val quiet = sqrt(energy / count) < .004 && peak < .025
        quietSamples = if (quiet) quietSamples + count else 0L
        return chunkSamples >= sampleRate.toLong() * minimumSeconds &&
            quietSamples >= sampleRate.toLong() * quietMilliseconds / 1000
    }

    fun reset() {
        quietSamples = 0L
    }
}
