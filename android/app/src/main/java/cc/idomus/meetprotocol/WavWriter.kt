package cc.idomus.meetprotocol

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale

/** Small, recoverable PCM WAV files. A .part file is never handed to the cloud worker. */
internal class WavWriter(private val partialFile: File) : Closeable {
    private val output = openNew(partialFile)
    private var closed = false
    private var finalSampleCount = 0L
    private val bytes = ByteArray(4096)

    init {
        try {
            require(output.length() == 0L) { "Refusing to overwrite audio" }
            writeHeader(output, 0)
        } catch (error: Exception) {
            try {
                output.close()
            } catch (closeError: Exception) {
                error.addSuppressed(closeError)
            }
            throw error
        }
    }

    val samplesWritten: Long
        get() =
            if (closed) finalSampleCount
            else ((output.length() - HEADER_BYTES).coerceAtLeast(0) / 2)

    fun append(samples: ShortArray, offset: Int, count: Int) {
        require(offset >= 0 && count >= 0 && offset <= samples.size - count)
        check(!closed)
        var position = offset
        val end = offset + count
        while (position < end) {
            val amount = minOf(bytes.size / 2, end - position)
            for (i in 0 until amount) {
                val sample = samples[position + i].toInt()
                bytes[i * 2] = sample.toByte()
                bytes[i * 2 + 1] = (sample ushr 8).toByte()
            }
            output.write(bytes, 0, amount * 2)
            position += amount
        }
    }

    /** Preserve a valid header and flush periodically, without buffering the meeting in memory. */
    fun checkpoint() {
        check(!closed)
        writeHeader(output, samplesWritten * 2)
        output.fd.sync()
    }

    override fun close() {
        if (closed) return
        try {
            val dataBytes = ((output.length() - HEADER_BYTES).coerceAtLeast(0) / 2) * 2
            finalSampleCount = dataBytes / 2
            output.setLength(HEADER_BYTES + dataBytes)
            writeHeader(output, dataBytes)
            output.fd.sync()
        } finally {
            closed = true
            output.close()
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val HEADER_BYTES = 44L
        private val filePattern = Regex("chunk-([0-9]{6,10})-start-([0-9]{12,19})\\.wav(\\.part)?")

        private fun openNew(file: File): RandomAccessFile {
            if (!file.createNewFile()) throw IOException("Refusing to overwrite audio")
            return RandomAccessFile(file, "rw")
        }

        fun chunkFile(directory: File, index: Int, startSamples: Long): File {
            require(index >= 0 && startSamples >= 0)
            return File(
                directory,
                String.format(Locale.ROOT, "chunk-%06d-start-%012d.wav.part", index, startSamples),
            )
        }

        fun parseName(file: File): Pair<Int, Long>? {
            val match = filePattern.matchEntire(file.name) ?: return null
            val index = match.groupValues[1].toIntOrNull() ?: return null
            val samples = match.groupValues[2].toLongOrNull() ?: return null
            if (samples > Long.MAX_VALUE / 1000 - Int.MAX_VALUE) return null
            return index to samples
        }

        /**
         * Repair a process-death partial (or an orphan finalized file) using actual PCM byte
         * length.
         */
        fun recover(file: File): AudioChunk? {
            val (index, startSamples) = parseName(file) ?: return null
            val sampleCount: Long
            RandomAccessFile(file, "rw").use { audio ->
                validateHeader(audio)
                val dataBytes = ((audio.length() - HEADER_BYTES) / 2) * 2
                require(dataBytes <= Int.MAX_VALUE.toLong() - HEADER_BYTES) {
                    "Audio chunk is too large"
                }
                audio.setLength(HEADER_BYTES + dataBytes)
                writeHeader(audio, dataBytes)
                audio.fd.sync()
                sampleCount = dataBytes / 2
            }
            if (sampleCount == 0L) {
                if (!file.delete()) throw IOException("Unable to remove empty audio chunk")
                return null
            }
            val finalFile =
                if (file.name.endsWith(".part")) {
                    File(file.parentFile, file.name.removeSuffix(".part")).also { destination ->
                        if (destination.exists())
                            throw IOException("Audio chunk destination already exists")
                        try {
                            Files.move(
                                file.toPath(),
                                destination.toPath(),
                                StandardCopyOption.ATOMIC_MOVE,
                            )
                        } catch (_: AtomicMoveNotSupportedException) {
                            Files.move(file.toPath(), destination.toPath())
                        }
                    }
                } else file
            return AudioChunk(
                finalFile,
                index,
                startSamples,
                Math.addExact(startSamples, sampleCount),
            )
        }

        fun sampleCount(file: File): Long =
            RandomAccessFile(file, "r").use {
                validateHeader(it)
                (it.length() - HEADER_BYTES) / 2
            }

        private fun validateHeader(file: RandomAccessFile) {
            if (file.length() < HEADER_BYTES) throw IOException("Incomplete WAV header")
            val header = ByteArray(HEADER_BYTES.toInt())
            file.seek(0)
            file.readFully(header)
            fun ascii(offset: Int, length: Int) = String(header, offset, length, Charsets.US_ASCII)
            fun little(offset: Int) =
                (header[offset].toInt() and 255) or ((header[offset + 1].toInt() and 255) shl 8)
            if (
                ascii(0, 4) != "RIFF" ||
                    ascii(8, 8) != "WAVEfmt " ||
                    ascii(36, 4) != "data" ||
                    little(16) != 16 ||
                    little(20) != 1 ||
                    little(22) != 1 ||
                    little(24) != SAMPLE_RATE ||
                    little(26) != 0 ||
                    little(34) != 16
            )
                throw IOException("Unexpected WAV format")
        }

        private fun writeHeader(file: RandomAccessFile, dataBytes: Long) {
            require(dataBytes in 0..(Int.MAX_VALUE.toLong() - HEADER_BYTES))
            file.seek(0)
            file.writeBytes("RIFF")
            file.writeInt(Integer.reverseBytes((36 + dataBytes).toInt()))
            file.writeBytes("WAVEfmt ")
            file.writeInt(Integer.reverseBytes(16))
            file.writeShort(java.lang.Short.reverseBytes(1.toShort()).toInt())
            file.writeShort(java.lang.Short.reverseBytes(1.toShort()).toInt())
            file.writeInt(Integer.reverseBytes(SAMPLE_RATE))
            file.writeInt(Integer.reverseBytes(SAMPLE_RATE * 2))
            file.writeShort(java.lang.Short.reverseBytes(2.toShort()).toInt())
            file.writeShort(java.lang.Short.reverseBytes(16.toShort()).toInt())
            file.writeBytes("data")
            file.writeInt(Integer.reverseBytes(dataBytes.toInt()))
            file.seek(file.length())
        }
    }
}

internal data class AudioChunk(
    val file: File,
    val index: Int,
    val startSamples: Long,
    val endSamples: Long,
)

/** Splits arbitrary AudioRecord read sizes without dropping or repeating boundary samples. */
internal class WavChunkSink(
    private val directory: File,
    private var nextIndex: Int,
    startingSamples: Long,
    private val onChunk: (AudioChunk) -> Unit,
    private val samplesPerChunk: Int = WavWriter.SAMPLE_RATE * 10,
    private val speechBoundary: SpeechChunkBoundary? = null,
) {
    private var committedSamples = startingSamples
    private var writer: WavWriter? = null
    private var partial: File? = null
    val totalSamples: Long
        get() = committedSamples + (writer?.samplesWritten ?: 0)

    init {
        require(samplesPerChunk > 0 && startingSamples >= 0 && nextIndex >= 0)
    }

    fun append(samples: ShortArray, count: Int) {
        require(count in 0..samples.size)
        var offset = 0
        while (offset < count) {
            val current =
                writer
                    ?: WavWriter(
                            WavWriter.chunkFile(directory, nextIndex, committedSamples).also {
                                partial = it
                            }
                        )
                        .also { writer = it }
            val amount =
                minOf(
                    count - offset,
                    samplesPerChunk - current.samplesWritten.toInt(),
                    speechBoundary?.frameSamples ?: Int.MAX_VALUE,
                )
            current.append(samples, offset, amount)
            val atSpeechBoundary =
                speechBoundary?.shouldFinish(samples, offset, amount, current.samplesWritten) ==
                    true
            offset += amount
            if (current.samplesWritten == samplesPerChunk.toLong() || atSpeechBoundary)
                finishChunk()
        }
    }

    fun checkpoint() = writer?.checkpoint()

    fun finishChunk() {
        val current = writer ?: return
        val file = checkNotNull(partial)
        current.close()
        writer = null
        partial = null
        val completed = WavWriter.recover(file) ?: return
        committedSamples = completed.endSamples
        nextIndex = Math.addExact(completed.index, 1)
        speechBoundary?.reset()
        onChunk(completed)
    }
}
