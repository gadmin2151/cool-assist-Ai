package cc.idomus.meetprotocol

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CloudPipelineTest {
    private val key = "sk-synthetic-fixture-key-never-valid"
    private val meeting = Meeting("meeting-fixture", "Тест", 1_700_000_000_000)

    private fun segment(index: Int, text: String) =
        Segment(
            "segment-$index",
            meeting.id,
            index,
            index * 10_000L,
            (index + 1) * 10_000L,
            "/not-exported/private.wav",
            text,
            SegmentState.DONE,
        )

    private fun brief(index: Int = 0) =
        Brief(
            "Обсудили тестирование прототипа.",
            listOf(
                BriefPoint(
                    "Срок",
                    "Следующая итерация — ориентир, точный срок не подтверждён.",
                    listOf(index),
                )
            ),
            emptyList(),
            listOf(ActionProposal("Уточнить план проверки", "", "", listOf(index))),
            listOf("Когда завершится проверка?"),
        )

    private fun response(brief: Brief) =
        JSONObject()
            .put("status", "completed")
            .put(
                "output",
                JSONArray()
                    .put(
                        JSONObject()
                            .put("type", "message")
                            .put(
                                "content",
                                JSONArray()
                                    .put(
                                        JSONObject()
                                            .put("type", "output_text")
                                            .put("text", BriefJson.encode(brief).toString())
                                    ),
                            )
                    ),
            )
            .toString()

    @Test
    fun errorsAreActionableAndNeverIncludeServerSecrets() {
        val privateMessage = "sk-private-value private meeting text"
        val auth = OpenAIClient.errorForStatus(401, """{"error":{"message":"$privateMessage"}}""")
        assertTrue(auth.credentialFailure)
        assertFalse(auth.retryable)
        assertFalse(auth.message!!.contains(privateMessage))
        val quota = OpenAIClient.errorForStatus(429, """{"error":{"code":"insufficient_quota"}}""")
        assertTrue(quota.credentialFailure)
        assertFalse(quota.retryable)
        assertTrue(OpenAIClient.errorForStatus(429, "{}").retryable)
        assertTrue(OpenAIClient.errorForStatus(503, "{}").retryable)
        assertFalse(OpenAIClient.errorForStatus(400, "{}").retryable)
    }

    @Test
    fun structuredOutputRequiresCompleteResponseAndGroundedIndexes() {
        assertEquals(
            brief(),
            BriefJson.decode(OpenAIClient.extractOutput(JSONObject(response(brief())))),
        )
        assertThrows(ApiFailure::class.java) {
            OpenAIClient.extractOutput(JSONObject(response(brief())).put("status", "incomplete"))
        }
        assertThrows(ApiFailure::class.java) { BriefJson.validate(brief(99), setOf(0, 1)) }
        assertThrows(ApiFailure::class.java) {
            BriefJson.validate(
                brief().copy(actions = listOf(ActionProposal("Invented", "", "", emptyList()))),
                setOf(0),
            )
        }
        assertThrows(ApiFailure::class.java) { BriefJson.decode("""{"introduction":"partial"}""") }
    }

    @Test
    fun schemaRequiresEveryFieldAndRejectsAdditionalProperties() {
        fun verifyObject(schema: JSONObject) {
            assertFalse(schema.getBoolean("additionalProperties"))
            val fields = schema.getJSONObject("properties").keys().asSequence().toSet()
            val required = schema.getJSONArray("required")
            assertEquals(fields, (0 until required.length()).map { required.getString(it) }.toSet())
        }
        val schema = BriefJson.schema()
        verifyObject(schema)
        verifyObject(
            schema.getJSONObject("properties").getJSONObject("points").getJSONObject("items")
        )
        verifyObject(
            schema.getJSONObject("properties").getJSONObject("actions").getJSONObject("items")
        )
    }

    @Test
    fun longTranscriptBatchesPreserveEveryCharacterAndOriginalIndex() {
        val sources =
            listOf(
                segment(4, "Содержание конца " + "z".repeat(8_000)),
                segment(0, "Начало " + "текст с кавычками \" и переносом\n".repeat(1_500)),
                segment(1, "Вторая тема " + "b".repeat(24_000)),
            )
        val batches = SummaryInput.transcriptBatches(sources)
        assertTrue(batches.size > 2)
        assertTrue(batches.all { it.length <= 28_000 })
        val reconstructed =
            batches
                .flatMap { it.lines() }
                .map(::JSONObject)
                .groupBy { it.getInt("source") }
                .mapValues { (_, fragments) -> fragments.joinToString("") { it.getString("text") } }
        sources.forEach { assertEquals(it.text, reconstructed[it.index]) }
        assertEquals(setOf(0, 1, 4), batches.flatMap { SummaryInput.sourceIndexes(it) }.toSet())
    }

    @Test
    fun markdownPreservesFullTranscriptNotesAndPendingMarkers() {
        val first = segment(0, "Начало " + "длинная речь ".repeat(5_000))
        val pending = segment(1, "").copy(state = SegmentState.PENDING)
        val last = segment(2, "Конец встречи не потерян")
        val result =
            exportMarkdown(
                meeting.copy(
                    capture = CaptureState.INTERRUPTED,
                    summary = brief(),
                    summaryRequested = true,
                    notes = "Личные заметки",
                ),
                listOf(last, pending, first),
                listOf(MeetingTask("task", meeting.id, "Позвонить", "Анна", "Ориентир — завтра")),
            )
        assertTrue(result.contains(first.text))
        assertTrue(result.contains(last.text))
        assertTrue(result.indexOf(first.text) < result.indexOf(last.text))
        assertTrue(result.contains("ещё не распознан"))
        assertTrue(result.contains("Запись прервалась"))
        assertTrue(result.contains("Личные заметки"))
        assertTrue(result.contains("Позвонить"))
        assertTrue(result.contains("#fragment-0"))
        assertFalse(result.contains("private.wav"))
    }

    @Test
    fun markdownTreatsModelAndMeetingTextAsTextRatherThanHtmlOrImages() {
        val text = "<script>alert(1)</script> ![image](https://bad.test)"
        val exported =
            exportMarkdown(meeting.copy(title = text), listOf(segment(0, text)), emptyList())
        assertFalse(exported.contains("<script>"))
        assertFalse(exported.contains("![image]("))
        assertTrue(exported.contains("&lt;script&gt;"))
    }

    @Test
    fun reductionEvidenceContainsOnlySourcesActuallyProvidedInItsBatch() {
        val first =
            Brief(
                "Первая часть",
                listOf(BriefPoint("Тема", "Факт", listOf(2))),
                emptyList(),
                emptyList(),
                emptyList(),
            )
        val next =
            Brief(
                "Вторая часть",
                emptyList(),
                emptyList(),
                listOf(ActionProposal("Уточнить", "", "", listOf(8))),
                emptyList(),
            )
        assertEquals(
            setOf(2),
            SummaryInput.briefSourceIndexes(SummaryInput.briefRecords(first).joinToString("\n")),
        )
        assertEquals(
            setOf(8),
            SummaryInput.briefSourceIndexes(SummaryInput.briefRecords(next).joinToString("\n")),
        )
        assertTrue(
            runCatching { BriefJson.validate(first, setOf(8)) }.exceptionOrNull() is ApiFailure
        )
    }

    @Test
    fun keyCheckUsesModelsEndpointAndReturnsSortedIds() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse()
                    .setBody("""{"data":[{"id":"gpt-5.4"},{"id":"gpt-4.1"},{"id":"gpt-5.4"}]}""")
            )
            val models = OpenAIClient.forTesting(server.url("/v1/")).checkKey(key)
            assertEquals(listOf("gpt-4.1", "gpt-5.4"), models)
            val request = server.takeRequest()
            assertEquals("/v1/models", request.path)
            assertEquals("GET", request.method)
            assertEquals("Bearer $key", request.getHeader("Authorization"))
        }
    }

    @Test
    fun redirectsAreNotFollowedWithCredentials() = runBlocking {
        MockWebServer().use { source ->
            MockWebServer().use { target ->
                source.enqueue(
                    MockResponse().setResponseCode(302).setHeader("Location", target.url("/steal"))
                )
                val failure =
                    runCatching { OpenAIClient.forTesting(source.url("/v1/")).checkKey(key) }
                        .exceptionOrNull()
                assertTrue(failure is ApiFailure)
                assertNull(target.takeRequest(100, TimeUnit.MILLISECONDS))
            }
        }
    }

    @Test
    fun fileTranscriptionUsesSnapshotLanguageAndJson() = runBlocking {
        MockWebServer().use { server ->
            val file = File.createTempFile("meeting-fixture", ".wav")
            try {
                val audio = ByteArray(100) { it.toByte() }
                file.writeBytes(audio)
                server.enqueue(MockResponse().setBody("""{"text":"Исходная речь"}"""))
                assertEquals(
                    "Исходная речь",
                    OpenAIClient.forTesting(server.url("/v1/"))
                        .transcribe(key, "gpt-4o-mini-transcribe", "ro", file, "Предыдущая реплика"),
                )
                val request = server.takeRequest()
                val multipart = request.body.readUtf8()
                val boundary =
                    request.getHeader("Content-Type")!!.toMediaType().parameter("boundary")!!
                val parts =
                    multipart.split("--$boundary").drop(1).dropLast(1).associate { section ->
                        val part = section.removePrefix("\r\n").removeSuffix("\r\n")
                        val separator = part.indexOf("\r\n\r\n")
                        assertTrue(
                            "Each multipart part must separate its headers and body",
                            separator >= 0,
                        )
                        val headers =
                            part.substring(0, separator).split("\r\n").associate { header ->
                                header.substringBefore(':').lowercase() to
                                    header.substringAfter(':').trim()
                            }
                        val disposition = headers.getValue("content-disposition")
                        val name =
                            Regex("(?:^|;\\s*)name=\"([^\"]+)\"").find(disposition)!!.groupValues[1]
                        name to (headers to part.substring(separator + 4))
                    }
                assertEquals("/v1/audio/transcriptions", request.path)
                assertEquals(
                    setOf("model", "response_format", "file", "language", "prompt"),
                    parts.keys,
                )
                assertEquals("ro", parts.getValue("language").second)
                assertEquals("gpt-4o-mini-transcribe", parts.getValue("model").second)
                assertEquals("json", parts.getValue("response_format").second)
                assertEquals("Предыдущая реплика", parts.getValue("prompt").second)
                val (fileHeaders, fileContents) = parts.getValue("file")
                assertTrue(
                    fileHeaders
                        .getValue("content-disposition")
                        .contains("filename=\"fragment.wav\"")
                )
                assertEquals("audio/wav", fileHeaders["content-type"])
                assertArrayEquals(audio, fileContents.toByteArray(Charsets.UTF_8))
                assertFalse(multipart.contains(file.path))
            } finally {
                file.delete()
            }
        }
    }

    @Test
    fun summaryUsesResponsesStoreFalseAndExcludesPrivateNotes() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(response(brief())))
            val input = segment(0, "Точная дата не подтверждена")
            val result =
                OpenAIClient.forTesting(server.url("/v1/"))
                    .summarize(
                        key,
                        "gpt-5.4",
                        meeting.copy(notes = "NEVER UPLOAD PRIVATE NOTES"),
                        listOf(input),
                    )
            assertEquals(brief(), result)
            val request = server.takeRequest()
            val raw = request.body.readUtf8()
            val json = JSONObject(raw)
            assertEquals("/v1/responses", request.path)
            assertFalse(json.getBoolean("store"))
            assertEquals(
                "json_schema",
                json.getJSONObject("text").getJSONObject("format").getString("type"),
            )
            assertTrue(raw.contains(input.text))
            assertFalse(raw.contains("NEVER UPLOAD PRIVATE NOTES"))
        }
    }

    @Test
    fun longSummaryCachesEveryPartAndDoesNotRepeatPaidRequests() = runBlocking {
        MockWebServer().use { server ->
            server.dispatcher =
                object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse {
                        val input = JSONObject(request.body.readUtf8()).getString("input")
                        val index =
                            input
                                .lines()
                                .drop(1)
                                .map(::JSONObject)
                                .firstOrNull { it.has("source") }
                                ?.getInt("source")
                                ?: SummaryInput.briefSourceIndexes(
                                        input.lines().drop(1).joinToString("\n")
                                    )
                                    .firstOrNull()
                                ?: 0
                        return MockResponse().setBody(response(brief(index)))
                    }
                }
            val saved = mutableMapOf<String, Brief>()
            val checkpoint =
                object : SummaryCheckpoint {
                    override fun read(key: String) = saved[key]

                    override fun write(key: String, brief: Brief) {
                        saved[key] = brief
                    }
                }
            val inputs = (0..12).map { segment(it, "Срок лишь ориентировочный ".repeat(500)) }
            val client = OpenAIClient.forTesting(server.url("/v1/"))
            client.summarize(key, "gpt-5.4", meeting, inputs, checkpoint)
            val count = server.requestCount
            assertTrue(count > 2)
            assertEquals(count, saved.size)
            client.summarize(key, "gpt-5.4", meeting, inputs, checkpoint)
            assertEquals(count, server.requestCount)
        }
    }

    @Test
    fun cancellingNetworkDoesNotWaitForCallTimeout() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val job = launch { OpenAIClient.forTesting(server.url("/v1/")).checkKey(key) }
            while (server.requestCount == 0) delay(10)
            val start = System.nanoTime()
            job.cancelAndJoin()
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 2_000)
        }
    }

    @Test
    fun changingCredentialsInvalidatesQueuedOldClient() = runBlocking {
        MockWebServer().use { server ->
            val client = OpenAIClient.forTesting(server.url("/v1/"))
            OpenAIClient.credentialsUpdated()
            val failure = runCatching { client.checkKey(key) }.exceptionOrNull()
            assertTrue(failure is ApiFailure && failure.credentialsChanged)
            assertEquals(0, server.requestCount)
        }
    }

    @Test
    fun changingCredentialsWhileReadingUnauthorizedBodyPreservesReplacementKey() = runBlocking {
        verifyCredentialChangeDuringResponse(401, beforeRead = true)
    }

    @Test
    fun changingCredentialsAfterBodyReadDiscardsOldSuccessAndUnauthorizedResponse() = runBlocking {
        verifyCredentialChangeDuringResponse(200, beforeRead = false)
        verifyCredentialChangeDuringResponse(401, beforeRead = false)
    }

    private suspend fun verifyCredentialChangeDuringResponse(status: Int, beforeRead: Boolean) {
        MockWebServer().use { server ->
            val reachedBody = CompletableDeferred<Unit>()
            val releaseBody = CountDownLatch(1)
            val listener =
                object : EventListener() {
                    private fun holdBody() {
                        reachedBody.complete(Unit)
                        check(releaseBody.await(5, TimeUnit.SECONDS)) {
                            "Test did not release the response body"
                        }
                    }

                    override fun responseBodyStart(call: Call) {
                        if (beforeRead) holdBody()
                    }

                    override fun responseBodyEnd(call: Call, byteCount: Long) {
                        if (!beforeRead) holdBody()
                    }
                }
            val body =
                if (status == 200) """{"data":[{"id":"gpt-4.1"}]}"""
                else """{"error":{"message":"synthetic unauthorized response"}}"""
            server.enqueue(MockResponse().setResponseCode(status).setBody(body))
            val oldClient = OpenAIClient.forTesting(server.url("/v1/"), listener)
            kotlinx.coroutines.coroutineScope {
                val result = async { runCatching { oldClient.checkKey(key) }.exceptionOrNull() }
                try {
                    withTimeout(3_000) { reachedBody.await() }
                    OpenAIClient.credentialsUpdated()
                } finally {
                    releaseBody.countDown()
                }
                val failure = withTimeout(3_000) { result.await() }
                assertTrue("Old response must be marked as superseded", failure is ApiFailure)
                failure as ApiFailure
                assertTrue(failure.credentialsChanged)
                assertFalse(failure.credentialFailure)
                assertFalse(failure.retryable)
            }
            server.enqueue(MockResponse().setBody("""{"data":[{"id":"gpt-4.1"}]}"""))
            assertEquals(
                listOf("gpt-4.1"),
                OpenAIClient.forTesting(server.url("/v1/")).checkKey(key),
            )
            assertEquals(2, server.requestCount)
        }
    }
}
