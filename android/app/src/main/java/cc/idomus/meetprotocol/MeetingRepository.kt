package cc.idomus.meetprotocol

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** All operations are synchronous and serialized. Call from Dispatchers.IO. */
class MeetingRepository(context: Context) {
    private val appContext = context.applicationContext
    private val root = File(appContext.filesDir, "meetings")
    private val database = Database(appContext)
    private val changed = MutableStateFlow(0L)
    val revision: StateFlow<Long> = changed.asStateFlow()
    private val db
        get() = database.writableDatabase

    @Synchronized
    fun meetings(): List<Meeting> =
        db.query("meetings", null, null, null, null, null, "created_at DESC, id").use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.toMeeting()) }
        }

    @Synchronized
    fun meeting(id: String): Meeting? {
        validateID(id)
        return db.query("meetings", null, "id = ?", arrayOf(id), null, null, null).use {
            if (it.moveToFirst()) it.toMeeting() else null
        }
    }

    @Synchronized
    fun segments(id: String): List<Segment> {
        validateID(id)
        return db.query(
                "segments",
                null,
                "meeting_id = ?",
                arrayOf(id),
                null,
                null,
                "segment_index",
            )
            .use { cursor -> buildList { while (cursor.moveToNext()) add(cursor.toSegment()) } }
    }

    @Synchronized
    fun tasks(): List<MeetingTask> =
        db.query("tasks", null, null, null, null, null, "created_at, id").use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(
                    MeetingTask(
                        cursor.string("id"),
                        cursor.string("meeting_id"),
                        cursor.string("text"),
                        cursor.string("owner"),
                        cursor.string("due"),
                        cursor.long("done") == 1L,
                    )
                )
            }
        }

    @Synchronized
    fun createMeeting(title: String, settings: AppSettings): Meeting {
        SettingsStore.validate(settings)
        val value =
            Meeting(
                UUID.randomUUID().toString(),
                cleanTitle(title),
                System.currentTimeMillis(),
                summaryModel = settings.summaryModel.trim(),
                transcriptionModel = settings.transcriptionModel.trim(),
            )
        db.insertOrThrow(
            "meetings",
            null,
            ContentValues().apply {
                put("id", value.id)
                put("title", value.title)
                put("created_at", value.createdAt)
                put("summary_model", value.summaryModel)
                put("transcription_model", value.transcriptionModel)
                put("language", settings.language.trim().ifBlank { "auto" })
            },
        )
        signal()
        return value
    }

    @Synchronized
    fun setCapture(id: String, state: CaptureState, durationMs: Long) {
        val current = meeting(id) ?: return
        require(durationMs >= 0) { "Некорректная длительность записи" }
        // Never shorten an already persisted recording during a late UI/service update.
        update(
            id,
            ContentValues().apply {
                put("capture", state.name)
                put("duration_ms", maxOf(current.durationMs, durationMs))
            },
        )
    }

    @Synchronized
    fun setProcessing(id: String, state: ProcessState, error: String = "") {
        update(
            id,
            ContentValues().apply {
                put("processing", state.name)
                put("error", error.take(1_000))
            },
        )
    }

    @Synchronized
    fun addSegment(segment: Segment) {
        validateID(segment.id)
        val meeting =
            meeting(segment.meetingId) ?: throw IllegalArgumentException("Встреча удалена")
        require(segment.index >= 0 && segment.startMs >= 0 && segment.endMs >= segment.startMs)
        val file = File(segment.audioPath).canonicalFile
        val directory = meetingDirectory(meeting.id).canonicalFile
        require(file.parentFile == directory && file.extension == "wav" && file.isFile) {
            "Аудиофрагмент не найден в папке встречи"
        }
        val values =
            ContentValues().apply {
                put("id", segment.id)
                put("meeting_id", segment.meetingId)
                put("segment_index", segment.index)
                put("start_ms", segment.startMs)
                put("end_ms", segment.endMs)
                put("audio_path", file.path)
                put("text", segment.text)
                put("state", segment.state.name)
            }
        val inserted =
            db.insertWithOnConflict("segments", null, values, SQLiteDatabase.CONFLICT_IGNORE)
        if (inserted != -1L) signal()
        else {
            val existing = segments(meeting.id).firstOrNull { it.index == segment.index }
            require(
                existing != null &&
                    existing.id == segment.id &&
                    existing.audioPath == file.path &&
                    existing.startMs == segment.startMs &&
                    existing.endMs == segment.endMs
            ) {
                "Конфликт аудиофрагмента; исходная запись сохранена"
            }
        }
    }

    @Synchronized
    fun completeSegment(id: String, text: String) {
        validateID(id)
        require(text.length <= 100_000) { "Ответ распознавания слишком большой" }
        if (
            db.update(
                "segments",
                ContentValues().apply {
                    put("text", text)
                    put("state", SegmentState.DONE.name)
                },
                "id = ? AND state = ?",
                arrayOf(id, SegmentState.PENDING.name),
            ) > 0
        )
            signal()
    }

    @Synchronized
    fun completeSegmentIfCurrent(segment: Segment, generation: Long, text: String): Boolean {
        if (
            meeting(segment.meetingId) == null ||
                processingPaused(segment.meetingId) ||
                transcriptionGeneration(segment.meetingId) != generation
        )
            return false
        completeSegment(segment.id, text)
        db.update(
            "meetings",
            ContentValues().apply {
                put("live_failures", 0)
                put("live_retry_at", 0L)
            },
            "id = ?",
            arrayOf(segment.meetingId),
        )
        return true
    }

    @Synchronized
    fun requestSummary(id: String, model: String) {
        SettingsStore.validateModel(model)
        if (meeting(id) == null) return
        db.execSQL(
            "UPDATE meetings SET summary_requested = 1, summary_model = ?, " +
                "summary_generation = summary_generation + 1 WHERE id = ?",
            arrayOf(model.trim(), id),
        )
        signal()
    }

    @Synchronized
    fun saveSummary(id: String, brief: Brief) {
        val meeting = meeting(id) ?: return
        update(
            id,
            ContentValues().apply {
                put("summary_json", BriefJson.encode(brief).toString())
                put("summary_requested", 0)
                put("generated_summary_model", meeting.summaryModel)
                put("processing", ProcessState.COMPLETE.name)
                put("error", "")
            },
        )
    }

    /** An older in-flight request may finish after the user selected another model. */
    @Synchronized
    fun saveSummaryIfCurrent(id: String, generation: Long, brief: Brief): Boolean {
        val meeting = meeting(id) ?: return false
        if (
            summaryGeneration(id) != generation ||
                !meeting.summaryRequested ||
                processingPaused(id) ||
                meeting.capture == CaptureState.RECORDING ||
                meeting.capture == CaptureState.PAUSED ||
                segments(id).any { it.state != SegmentState.DONE }
        )
            return false
        saveSummary(id, brief)
        return true
    }

    @Synchronized
    fun rename(id: String, title: String) =
        update(id, ContentValues().apply { put("title", cleanTitle(title)) })

    @Synchronized
    fun saveNotes(id: String, notes: String) {
        require(notes.length <= 1_000_000) { "Заметки слишком длинные" }
        update(id, ContentValues().apply { put("notes", notes) })
    }

    @Synchronized
    fun addTask(meetingId: String, text: String, owner: String = "", due: String = "") {
        require(meeting(meetingId) != null) { "Встреча удалена" }
        require(
            text.isNotBlank() &&
                text.length <= 10_000 &&
                owner.length <= 1_000 &&
                due.length <= 1_000
        )
        val exists =
            db.query(
                    "tasks",
                    arrayOf("id"),
                    "meeting_id = ? AND text = ? AND owner = ? AND due = ?",
                    arrayOf(meetingId, text.trim(), owner.trim(), due.trim()),
                    null,
                    null,
                    null,
                    "1",
                )
                .use { it.moveToFirst() }
        if (exists) return
        db.insertOrThrow(
            "tasks",
            null,
            ContentValues().apply {
                put("id", UUID.randomUUID().toString())
                put("meeting_id", meetingId)
                put("text", text.trim())
                put("owner", owner.trim())
                put("due", due.trim())
                put("created_at", System.currentTimeMillis())
            },
        )
        signal()
    }

    @Synchronized
    fun toggleTask(id: String, done: Boolean) {
        validateID(id)
        if (
            db.update(
                "tasks",
                ContentValues().apply { put("done", if (done) 1 else 0) },
                "id = ?",
                arrayOf(id),
            ) > 0
        )
            signal()
    }

    @Synchronized
    fun deleteTask(id: String) {
        validateID(id)
        if (db.delete("tasks", "id = ?", arrayOf(id)) > 0) signal()
    }

    @Synchronized
    fun deleteMeeting(id: String) {
        val value = meeting(id) ?: return
        require(value.capture != CaptureState.RECORDING && value.capture != CaptureState.PAUSED) {
            "Сначала остановите запись"
        }
        val directory = checkedDirectory(id)
        // Keep a durable tombstone before removing files; workers cannot resurrect deleted data.
        update(id, ContentValues().apply { put("queue_paused", 1) })
        if (directory.exists() && !deleteContained(directory, directory.canonicalFile)) {
            throw IOException("Не удалось удалить файлы встречи. Повторите удаление.")
        }
        db.delete("meetings", "id = ?", arrayOf(id))
        signal()
    }

    @Synchronized
    fun recoverInterrupted() {
        db.execSQL(
            "UPDATE meetings SET capture = ?, error = CASE WHEN error = '' THEN ? ELSE error END WHERE capture IN (?, ?)",
            arrayOf(
                CaptureState.INTERRUPTED.name,
                "Запись прервалась. Сохранённые фрагменты можно обработать.",
                CaptureState.RECORDING.name,
                CaptureState.PAUSED.name,
            ),
        )
        db.execSQL(
            "UPDATE meetings SET processing = ? WHERE processing IN (?, ?)",
            arrayOf(
                ProcessState.IDLE.name,
                ProcessState.TRANSCRIBING.name,
                ProcessState.SUMMARIZING.name,
            ),
        )
        signal()
    }

    @Synchronized
    fun meetingDirectory(id: String): File =
        checkedDirectory(id).also {
            require(meeting(id) != null) { "Встреча удалена" }
            if (!it.isDirectory && !it.mkdirs())
                throw IOException("Не удалось создать папку записи")
        }

    @Synchronized fun language(id: String): String = field(id, "language") ?: "auto"

    @Synchronized
    fun summaryGeneration(id: String): Long = field(id, "summary_generation")?.toLongOrNull() ?: -1

    @Synchronized
    fun transcriptionGeneration(id: String): Long =
        field(id, "asr_generation")?.toLongOrNull() ?: -1

    @Synchronized fun processingPaused(id: String): Boolean = field(id, "queue_paused") != "0"

    @Synchronized fun pauseReason(id: String): String = field(id, "pause_reason").orEmpty()

    @Synchronized
    fun pauseProcessing(id: String, message: String, reason: String = "error") =
        update(
            id,
            ContentValues().apply {
                put("queue_paused", 1)
                put("processing", ProcessState.ERROR.name)
                put("error", message.take(1_000))
                put("pause_reason", reason)
            },
        )

    @Synchronized
    fun resumeProcessing(id: String) =
        update(
            id,
            ContentValues().apply {
                put("queue_paused", 0)
                put("processing", ProcessState.IDLE.name)
                put("error", "")
                put("pause_reason", "")
                put("live_failures", 0)
                put("live_retry_at", 0L)
            },
        )

    @Synchronized
    fun reconfigurePending(id: String, settings: AppSettings) {
        SettingsStore.validate(settings)
        val value = meeting(id) ?: return
        val targetLanguage = settings.language.trim().ifBlank { "auto" }
        val updates = ContentValues()
        if (
            segments(id).any { it.state == SegmentState.PENDING } &&
                (value.transcriptionModel != settings.transcriptionModel.trim() ||
                    language(id) != targetLanguage)
        ) {
            updates.put("transcription_model", settings.transcriptionModel.trim())
            updates.put("language", targetLanguage)
            updates.put("asr_generation", transcriptionGeneration(id) + 1)
        }
        if (value.summaryRequested && value.summaryModel != settings.summaryModel.trim()) {
            updates.put("summary_model", settings.summaryModel.trim())
            updates.put("summary_generation", summaryGeneration(id) + 1)
        }
        if (updates.size() > 0) update(id, updates)
    }

    @Synchronized
    fun liveRetryAllowed(id: String): Boolean =
        !processingPaused(id) &&
            (field(id, "live_retry_at")?.toLongOrNull() ?: 0L) <= System.currentTimeMillis()

    @Synchronized
    fun recordLiveFailure(id: String, message: String) {
        val failures = (field(id, "live_failures")?.toIntOrNull() ?: 0) + 1
        if (failures >= 5) {
            pauseProcessing(
                id,
                "Автоматические попытки завершены. Проверьте интернет и нажмите «Повторить». Аудио сохранено.",
            )
        } else
            update(
                id,
                ContentValues().apply {
                    put("live_failures", failures)
                    put(
                        "live_retry_at",
                        System.currentTimeMillis() + 30_000L * (1L shl (failures - 1)),
                    )
                    put("processing", ProcessState.ERROR.name)
                    put("error", message.take(1_000))
                },
            )
    }

    @Synchronized
    fun cachedBrief(id: String, cacheKey: String): Brief? =
        db.query(
                "summary_cache",
                arrayOf("json"),
                "meeting_id = ? AND cache_key = ?",
                arrayOf(id, cacheKey),
                null,
                null,
                null,
            )
            .use { if (it.moveToFirst()) BriefJson.decode(it.getString(0)) else null }

    @Synchronized
    fun cacheBrief(id: String, cacheKey: String, brief: Brief) {
        if (meeting(id) == null) return
        db.insertWithOnConflict(
            "summary_cache",
            null,
            ContentValues().apply {
                put("meeting_id", id)
                put("cache_key", cacheKey)
                put("json", BriefJson.encode(brief).toString())
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun field(id: String, column: String): String? {
        validateID(id)
        return db.query("meetings", arrayOf(column), "id = ?", arrayOf(id), null, null, null).use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }

    private fun update(id: String, values: ContentValues) {
        validateID(id)
        if (db.update("meetings", values, "id = ?", arrayOf(id)) > 0) signal()
    }

    private fun signal() {
        changed.value += 1
    }

    private fun checkedDirectory(id: String): File {
        validateID(id)
        val directory = File(root, id)
        require(directory.canonicalFile.parentFile == root.canonicalFile) {
            "Недопустимая папка встречи"
        }
        return directory
    }

    private fun deleteContained(file: File, boundary: File): Boolean {
        // Do not follow symlinks outside the owned folder, including when traversing descendants.
        if (java.nio.file.Files.isSymbolicLink(file.toPath())) return file.delete()
        if (
            file.canonicalFile != boundary &&
                !file.canonicalPath.startsWith(boundary.path + File.separator)
        )
            return false
        if (file.isDirectory) {
            val children = file.listFiles() ?: return false
            for (child in children) if (!deleteContained(child, boundary)) return false
        }
        return !file.exists() || file.delete()
    }

    private fun Cursor.string(name: String) = getString(getColumnIndexOrThrow(name))

    private fun Cursor.long(name: String) = getLong(getColumnIndexOrThrow(name))

    private fun Cursor.toMeeting() =
        Meeting(
            id = string("id"),
            title = string("title"),
            createdAt = long("created_at"),
            durationMs = long("duration_ms"),
            capture = CaptureState.valueOf(string("capture")),
            processing = ProcessState.valueOf(string("processing")),
            error = string("error"),
            summary = string("summary_json").takeIf { it.isNotEmpty() }?.let(BriefJson::decode),
            summaryModel = string("summary_model"),
            transcriptionModel = string("transcription_model"),
            notes = string("notes"),
            summaryRequested = long("summary_requested") == 1L,
            generatedSummaryModel = string("generated_summary_model").takeIf { it.isNotEmpty() },
        )

    private fun Cursor.toSegment() =
        Segment(
            string("id"),
            string("meeting_id"),
            long("segment_index").toInt(),
            long("start_ms"),
            long("end_ms"),
            string("audio_path"),
            string("text"),
            SegmentState.valueOf(string("state")),
        )

    companion object {
        fun validateID(id: String) {
            require(
                runCatching { UUID.fromString(id).toString() == id.lowercase() }.getOrDefault(false)
            ) {
                "Некорректный идентификатор"
            }
        }

        private fun cleanTitle(title: String): String =
            title.trim().also {
                require(it.isNotEmpty() && it.length <= 300) { "Укажите название до 300 символов" }
            }
    }

    private class Database(context: Context) :
        SQLiteOpenHelper(context, "meet-protocol.db", null, 3) {
        init {
            setWriteAheadLoggingEnabled(true)
        }

        override fun onConfigure(db: SQLiteDatabase) {
            db.setForeignKeyConstraintsEnabled(true)
        }

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE meetings (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL DEFAULT 0, capture TEXT NOT NULL DEFAULT 'STOPPED',
                processing TEXT NOT NULL DEFAULT 'IDLE', error TEXT NOT NULL DEFAULT '',
                summary_json TEXT NOT NULL DEFAULT '', summary_model TEXT NOT NULL, generated_summary_model TEXT NOT NULL DEFAULT '',
                transcription_model TEXT NOT NULL, language TEXT NOT NULL DEFAULT 'auto', notes TEXT NOT NULL DEFAULT '',
                summary_requested INTEGER NOT NULL DEFAULT 0, summary_generation INTEGER NOT NULL DEFAULT 0,
                queue_paused INTEGER NOT NULL DEFAULT 0, pause_reason TEXT NOT NULL DEFAULT '',
                asr_generation INTEGER NOT NULL DEFAULT 0, live_failures INTEGER NOT NULL DEFAULT 0,
                live_retry_at INTEGER NOT NULL DEFAULT 0)"""
            )
            db.execSQL(
                """CREATE TABLE segments (
                id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                segment_index INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
                audio_path TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'PENDING',
                UNIQUE(meeting_id, segment_index))"""
            )
            db.execSQL(
                """CREATE TABLE tasks (
                id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                text TEXT NOT NULL, owner TEXT NOT NULL, due TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL)"""
            )
            db.execSQL("CREATE INDEX task_meeting ON tasks(meeting_id)")
            db.execSQL(
                """CREATE TABLE summary_cache (
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                cache_key TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(meeting_id, cache_key))"""
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2)
                db.execSQL(
                    "ALTER TABLE meetings ADD COLUMN generated_summary_model TEXT NOT NULL DEFAULT ''"
                )
            if (oldVersion < 3) {
                db.execSQL("ALTER TABLE meetings ADD COLUMN pause_reason TEXT NOT NULL DEFAULT ''")
                db.execSQL(
                    "ALTER TABLE meetings ADD COLUMN asr_generation INTEGER NOT NULL DEFAULT 0"
                )
                db.execSQL(
                    "ALTER TABLE meetings ADD COLUMN live_failures INTEGER NOT NULL DEFAULT 0"
                )
                db.execSQL(
                    "ALTER TABLE meetings ADD COLUMN live_retry_at INTEGER NOT NULL DEFAULT 0"
                )
            }
        }
    }
}
