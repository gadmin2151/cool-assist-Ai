package cc.idomus.meetprotocol

import java.io.RandomAccessFile
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class SpeechChunkBoundaryTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `prefer a quiet gap after six seconds without dropping a single sample`() {
        val chunks = mutableListOf<AudioChunk>()
        val sink =
            WavChunkSink(
                temporary.newFolder(),
                0,
                0,
                chunks::add,
                samplesPerChunk = WavWriter.SAMPLE_RATE * 14,
                speechBoundary = SpeechChunkBoundary(),
            )
        val input =
            ShortArray(WavWriter.SAMPLE_RATE * 20) { i ->
                if (i % (WavWriter.SAMPLE_RATE * 7) < WavWriter.SAMPLE_RATE * 6) 3000.toShort()
                else 0
            }
        var offset = 0
        while (offset < input.size) {
            val amount = minOf(1597, input.size - offset)
            sink.append(input.copyOfRange(offset, offset + amount), amount)
            offset += amount
        }
        sink.finishChunk()
        assertTrue(
            chunks.first().endSamples in (WavWriter.SAMPLE_RATE * 6L)..(WavWriter.SAMPLE_RATE * 7L)
        )
        assertEquals(input.size.toLong(), sink.totalSamples)
        chunks.zipWithNext().forEach { (left, right) ->
            assertEquals(left.endSamples, right.startSamples)
        }
        val actual =
            chunks
                .flatMap { chunk ->
                    RandomAccessFile(chunk.file, "r").use { file ->
                        file.seek(44)
                        List(((file.length() - 44) / 2).toInt()) {
                            java.lang.Short.reverseBytes(file.readShort())
                        }
                    }
                }
                .toShortArray()
        assertArrayEquals(input, actual)
    }

    @Test
    fun `continuous speech has bounded latency and final short chunk survives`() {
        val chunks = mutableListOf<AudioChunk>()
        val sink =
            WavChunkSink(
                temporary.newFolder(),
                0,
                0,
                chunks::add,
                samplesPerChunk = WavWriter.SAMPLE_RATE * 14,
                speechBoundary = SpeechChunkBoundary(),
            )
        repeat(31) {
            sink.append(ShortArray(WavWriter.SAMPLE_RATE) { 2500 }, WavWriter.SAMPLE_RATE)
        }
        sink.finishChunk()
        assertEquals(
            listOf(14L, 14L, 3L),
            chunks.map { (it.endSamples - it.startSamples) / WavWriter.SAMPLE_RATE },
        )
    }

    @Test
    fun `quiet speech is preserved instead of discarded as silence`() {
        val chunks = mutableListOf<AudioChunk>()
        val sink =
            WavChunkSink(
                temporary.newFolder(),
                0,
                0,
                chunks::add,
                samplesPerChunk = WavWriter.SAMPLE_RATE * 14,
                speechBoundary = SpeechChunkBoundary(),
            )
        repeat(20) { sink.append(ShortArray(WavWriter.SAMPLE_RATE) { 2 }, WavWriter.SAMPLE_RATE) }
        sink.finishChunk()
        assertEquals(WavWriter.SAMPLE_RATE * 20L, chunks.sumOf { it.endSamples - it.startSamples })
        assertTrue(chunks.size >= 3)
    }

    @Test
    fun `pause resets the quiet detector and preserves timing`() {
        val chunks = mutableListOf<AudioChunk>()
        val sink =
            WavChunkSink(
                temporary.newFolder(),
                0,
                0,
                chunks::add,
                samplesPerChunk = WavWriter.SAMPLE_RATE * 14,
                speechBoundary = SpeechChunkBoundary(),
            )
        sink.append(ShortArray(100), 100)
        sink.finishChunk()
        sink.append(ShortArray(200) { 4000 }, 200)
        sink.finishChunk()
        assertEquals(300L, sink.totalSamples)
        assertEquals(100L, chunks[1].startSamples)
    }

    @Test
    fun `waveform reflects microphone levels and freezes exactly on pause`() {
        val history = LevelHistory(4)
        assertEquals(listOf(0f, 0f, 0f, 0.5f), history.append(.25f, false))
        val beforePause = history.append(.81f, false)
        repeat(20) { assertEquals(beforePause, history.append(1f, true)) }
        assertEquals(listOf(0f, .5f, .9f, 0f), history.append(Float.NaN, false))
        repeat(200) { history.append(100f, false) }
        assertEquals(List(4) { 1f }, history.append(1f, false))
    }
}
