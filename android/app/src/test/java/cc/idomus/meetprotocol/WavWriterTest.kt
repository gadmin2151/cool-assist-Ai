package cc.idomus.meetprotocol

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WavWriterTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `arbitrary read sizes preserve every sample across chunk boundaries`() {
        val directory = temporary.newFolder()
        val chunks = mutableListOf<AudioChunk>()
        val sink = WavChunkSink(directory, 0, 0, chunks::add, samplesPerChunk = 17)
        val expected = ShortArray(511) { (it * 257 - 32768).toShort() }
        var offset = 0
        listOf(1, 24, 17, 103, 366).forEach { size ->
            sink.append(expected.copyOfRange(offset, offset + size), size)
            offset += size
        }
        sink.finishChunk()
        assertEquals(511L, sink.totalSamples)
        assertEquals(31, chunks.size)
        assertEquals(0L, chunks.first().startSamples)
        assertEquals(511L, chunks.last().endSamples)
        chunks.zipWithNext().forEach { (first, second) ->
            assertEquals(first.endSamples, second.startSamples)
        }
        val actual = chunks.flatMap { readSamples(it.file).toList() }.toShortArray()
        assertArrayEquals(expected, actual)
        assertFalse(directory.listFiles().orEmpty().any { it.name.endsWith(".part") })
    }

    @Test
    fun `three hour recording streams 1080 complete chunks with exact timeline and bounded buffers`() {
        val directory = temporary.newFolder()
        val samplesPerChunk = WavWriter.SAMPLE_RATE * 10
        val expectedSamples = 3L * 60 * 60 * WavWriter.SAMPLE_RATE
        var chunkCount = 0
        var verifiedSamples = 0L
        val sink =
            WavChunkSink(
                directory,
                0,
                0,
                onChunk = { chunk ->
                    assertEquals(chunkCount, chunk.index)
                    assertEquals(chunkCount.toLong() * samplesPerChunk, chunk.startSamples)
                    assertEquals(chunk.startSamples + samplesPerChunk, chunk.endSamples)
                    assertEquals(WavWriter.HEADER_BYTES + samplesPerChunk * 2L, chunk.file.length())
                    assertEquals(samplesPerChunk.toLong(), WavWriter.sampleCount(chunk.file))
                    RandomAccessFile(chunk.file, "r").use { input ->
                        // Check both boundaries and a sample inside every chunk against a
                        // continuous
                        // absolute-index pattern. No full recording or full chunk is loaded into
                        // RAM.
                        listOf(0, samplesPerChunk / 2, samplesPerChunk - 1).forEach { offset ->
                            input.seek(WavWriter.HEADER_BYTES + offset * 2L)
                            assertEquals(
                                (chunk.startSamples + offset).toShort(),
                                java.lang.Short.reverseBytes(input.readShort()),
                            )
                        }
                    }
                    verifiedSamples += samplesPerChunk
                    chunkCount++
                },
            )
        // This size intentionally does not divide a ten-second chunk. The same ~20 KB array
        // is reused for all 172.8 million samples; WAV output (~345 MB) lives in TemporaryFolder.
        val buffer = ShortArray(10_007)
        var position = 0L
        while (position < expectedSamples) {
            val count = minOf(buffer.size.toLong(), expectedSamples - position).toInt()
            for (i in 0 until count) buffer[i] = (position + i).toShort()
            sink.append(buffer, count)
            position += count
        }
        sink.finishChunk()
        assertEquals(1080, chunkCount)
        assertEquals(expectedSamples, verifiedSamples)
        assertEquals(expectedSamples, sink.totalSamples)
        val files = directory.listFiles().orEmpty()
        assertEquals(1080, files.size)
        assertFalse(files.any { it.name.endsWith(".part") })
    }

    @Test
    fun `pause flush and resume preserve sample-based time and indexes`() {
        val chunks = mutableListOf<AudioChunk>()
        val sink =
            WavChunkSink(temporary.newFolder(), 4, 16003L, chunks::add, samplesPerChunk = 100)
        sink.append(shortArrayOf(1, 2, 3), 3)
        sink.finishChunk()
        sink.append(shortArrayOf(4, 5), 2)
        sink.finishChunk()
        assertEquals(listOf(4, 5), chunks.map { it.index })
        assertEquals(listOf(16003L, 16006L), chunks.map { it.startSamples })
        assertEquals(16008L, sink.totalSamples)
    }

    @Test
    fun `recovery repairs stale header and partial final sample`() {
        val file = WavWriter.chunkFile(temporary.newFolder(), 7, 192000)
        WavWriter(file).use { it.append(shortArrayOf(Short.MIN_VALUE, 10, Short.MAX_VALUE), 0, 3) }
        RandomAccessFile(file, "rw").use {
            it.seek(40)
            it.writeInt(
                0
            ) // The length header might not have been checkpointed before process death.
            it.seek(it.length())
            it.write(255) // A torn final PCM sample is discarded, never passed to the transcriber.
        }
        val result = WavWriter.recover(file)!!
        assertFalse(file.exists())
        assertEquals(192003L, result.endSamples)
        assertEquals(50L, result.file.length())
        assertArrayEquals(
            shortArrayOf(Short.MIN_VALUE, 10, Short.MAX_VALUE),
            readSamples(result.file),
        )
        assertEquals(3L, WavWriter.sampleCount(result.file))
        RandomAccessFile(result.file, "r").use {
            it.seek(40)
            assertEquals(6, Integer.reverseBytes(it.readInt()))
        }
        assertNotNull(
            WavWriter.recover(result.file)
        ) // Finalized but not yet registered DB file is recoverable too.
    }

    @Test
    fun `empty interrupted file does not prevent a new recording`() {
        val file = WavWriter.chunkFile(temporary.newFolder(), 0, 0)
        WavWriter(file).close()
        assertNull(WavWriter.recover(file))
        assertFalse(file.exists())
        WavWriter(file).close()
    }

    @Test
    fun `existing audio is never overwritten`() {
        val file = WavWriter.chunkFile(temporary.newFolder(), 0, 0)
        WavWriter(file).use { it.append(shortArrayOf(42), 0, 1) }
        val original = file.readBytes()
        try {
            WavWriter(file)
            throw AssertionError("Existing audio must be rejected")
        } catch (_: IOException) {}
        assertArrayEquals(original, file.readBytes())
    }

    @Test
    fun `damaged header and unrelated files are left untouched`() {
        val directory = temporary.newFolder()
        val file = WavWriter.chunkFile(directory, 0, 0)
        file.writeText("incomplete")
        try {
            WavWriter.recover(file)
            throw AssertionError("Invalid header must be rejected")
        } catch (_: IOException) {}
        assertEquals("incomplete", file.readText())
        val unrelated = File(directory, "notes.wav").apply { writeText("keep") }
        assertNull(WavWriter.recover(unrelated))
        assertTrue(unrelated.exists())
    }

    private fun readSamples(file: File): ShortArray =
        RandomAccessFile(file, "r").use { input ->
            input.seek(WavWriter.HEADER_BYTES)
            ShortArray(((input.length() - WavWriter.HEADER_BYTES) / 2).toInt()) {
                java.lang.Short.reverseBytes(input.readShort())
            }
        }
}
