package cc.idomus.meetprotocol

import android.os.ParcelFileDescriptor
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Uses only synthetic, completed records: no microphone, credential, or cloud request. */
@RunWith(AndroidJUnit4::class)
class WorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private lateinit var repository: MeetingRepository
    private val created = mutableListOf<String>()
    private lateinit var first: Meeting
    private lateinit var second: Meeting

    @Before
    fun createFixtures() {
        val graph = MeetProtocolApplication.graph(compose.activity)
        runBlocking { withTimeout(15_000) { graph.ready.first { it } } }
        repository = graph.repository
        first = fixture("QA Project ${System.nanoTime()}")
        second = fixture("QA Next ${System.nanoTime()}")
        addFixtureSegment(repository, first, 0, "QA Первая реплика: проверяем новую форму.")
        addFixtureSegment(
            repository,
            first,
            1,
            "QA Последняя реплика: срок проверки пока не подтверждён.",
        )
        repository.saveNotes(first.id, "QA Сверить список проверок.")
        repository.saveSummary(
            first.id,
            Brief(
                introduction = "QA Обсудили тестирование прототипа.",
                points =
                    listOf(BriefPoint("QA Проверка", "Новая форма проходит проверку.", listOf(0))),
                decisions = listOf("QA Проверить новую форму."),
                actions =
                    listOf(
                        ActionProposal(
                            "QA Уточнить срок проверки",
                            "QA Команда",
                            "Не подтверждён",
                            listOf(1),
                        )
                    ),
                questions = listOf("QA Какие проверки осталось выполнить?"),
            ),
        )
        addFixtureSegment(repository, second, 0, "QA Другую встречу можно открыть независимо.")
        repository.saveSummary(
            second.id,
            Brief("QA Вторая встреча.", emptyList(), emptyList(), emptyList(), emptyList()),
        )
        compose.waitUntil(10_000) { repository.meetings().any { it.id == first.id } }
        compose.waitForIdle()
    }

    @After
    fun deleteOnlyFixtures() {
        created.forEach { id ->
            MeetProtocolApplication.graph(compose.activity).queue.cancel(id)
            repository.meeting(id)?.let {
                repository.setCapture(id, CaptureState.STOPPED, it.durationMs)
            }
            repository.deleteMeeting(id)
        }
    }

    @Test
    fun navigationAndMeetingSwitchUseRealTouchTargets() {
        navigate("Настройки")
        compose.onNodeWithText("Всё готово к разговору").assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("Записать встречу").assertIsDisplayed()
        openMeeting(first)
        compose.onNodeWithText("QA Обсудили тестирование прототипа.").assertIsDisplayed()
        screenshot("meeting-brief")
        compose.onNodeWithText("Текст").performClick()
        compose.onNodeWithText("QA Первая реплика: проверяем новую форму.").assertIsDisplayed()
        scrollTo("QA Последняя реплика: срок проверки пока не подтверждён.")
        compose
            .onNodeWithText("QA Последняя реплика: срок проверки пока не подтверждён.")
            .assertIsDisplayed()
        screenshot("meeting-transcript")
        compose.onNodeWithContentDescription("К библиотеке").performClick()
        openMeeting(second)
        screenshot("meeting-second")
        compose.onNodeWithText("QA Вторая встреча.").assertIsDisplayed()
        compose.onNodeWithText("Текст").performClick()
        compose.onNodeWithText("QA Другую встречу можно открыть независимо.").assertIsDisplayed()
        compose.onNodeWithText("QA Первая реплика: проверяем новую форму.").assertDoesNotExist()
        navigate("Задачи")
        compose.onNodeWithText("От слов — к делам").assertIsDisplayed()
        navigate("Встречи")
        compose.onNodeWithText("Записать встречу").assertIsDisplayed()
    }

    @Test
    fun summarySourceOpensTheOriginalTranscript() {
        openMeeting(first)
        scrollTo("00:00")
        compose.onNodeWithText("00:00").performClick()
        compose.onNodeWithText("QA Первая реплика: проверяем новую форму.").assertIsDisplayed()
    }

    @Test
    fun activeMeetingShowsListeningControlsAndBookmarkWithoutBlockingOtherMeetings() {
        openMeeting(first)
        try {
            compose.runOnUiThread {
                CaptureController.publish(CaptureStatus(first.id, false, 65_000, .15f))
            }
            compose.onNodeWithText("Отметить важное").assertIsDisplayed().performClick()
            compose.waitUntil(5_000) {
                repository.meeting(first.id)?.notes?.contains("01:05") == true
            }
            compose.onNodeWithContentDescription("Уровень микрофона").assertIsDisplayed()
            screenshot("meeting-listening")
            compose.onNodeWithContentDescription("К библиотеке").performClick()
            openMeeting(second)
            screenshot("meeting-second-active")
            compose.onNodeWithText("QA Вторая встреча.").assertIsDisplayed()
            compose.onNodeWithContentDescription("Завершить запись").assertIsDisplayed()
        } finally {
            compose.runOnUiThread { CaptureController.publish(CaptureStatus()) }
        }
    }

    @Test
    fun keyInputIsMaskedAndUnsavedValueDoesNotSurviveLeavingSettings() {
        navigate("Настройки")
        val password =
            hasSetTextAction() and SemanticsMatcher.keyIsDefined(SemanticsProperties.Password)
        compose.onNode(password).assertExists()
        assertEquals(
            "",
            compose
                .onNode(password)
                .fetchSemanticsNode()
                .config[SemanticsProperties.EditableText]
                .text,
        )
        compose.onNode(password).performTextInput("fixture-placeholder-never-a-real-credential")
        compose.onNode(password).assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Password))
        navigate("Встречи")
        navigate("Настройки")
        assertEquals(
            "",
            compose
                .onNode(password)
                .fetchSemanticsNode()
                .config[SemanticsProperties.EditableText]
                .text,
        )
    }

    @Test
    fun actionProposalRequiresUserClickBeforeItBecomesTask() {
        openMeeting(first)
        assertTrue(repository.tasks().none { it.meetingId == first.id })
        scrollTo("Добавить в задачи")
        compose.onNodeWithText("Добавить в задачи").performClick()
        compose.waitUntil(10_000) { repository.tasks().any { it.meetingId == first.id } }
        val task = repository.tasks().single { it.meetingId == first.id }
        assertEquals("QA Уточнить срок проверки", task.text)
        assertEquals("Не подтверждён", task.due)
        navigate("Задачи")
        compose.onNodeWithText(task.text).assertIsDisplayed()
    }

    @Test
    fun manualTaskDialogCancelsAndCommitsOnlyOnConfirmation() {
        openMeeting(first)
        compose.onNodeWithText("Заметки").performClick()
        scrollTo("Добавить")
        compose.onNodeWithText("Добавить").performClick()
        compose
            .onNode(hasSetTextAction() and hasText("Что нужно сделать"))
            .performTextInput("QA Проверить состояния кнопок")
        assertTrue(repository.tasks().none { it.meetingId == first.id })
        compose.onNodeWithText("Отмена").performClick()
        assertTrue(repository.tasks().none { it.meetingId == first.id })
        compose.onNodeWithText("Добавить").performClick()
        compose
            .onNode(hasSetTextAction() and hasText("Что нужно сделать"))
            .performTextInput("QA Проверить состояния кнопок")
        compose.onNode(hasText("Добавить") and hasAnyAncestor(isDialog())).performClick()
        compose.waitUntil(10_000) { repository.tasks().any { it.meetingId == first.id } }
        assertEquals(
            "QA Проверить состояния кнопок",
            repository.tasks().single { it.meetingId == first.id }.text,
        )
    }

    @Test
    fun markdownContainsEntireChronologyNotesAndAcceptedTasks() {
        repository.addTask(first.id, "QA Проверить чек-лист", "QA Тестировщик", "Не назначен")
        val meeting = requireNotNull(repository.meeting(first.id))
        val markdown =
            exportMarkdown(
                meeting,
                repository.segments(first.id),
                repository.tasks().filter { it.meetingId == first.id },
            )
        assertTrue(markdown.contains(markdownText(first.title)))
        assertTrue(markdown.contains(markdownText("QA Первая реплика: проверяем новую форму.")))
        assertTrue(
            markdown.contains(
                markdownText("QA Последняя реплика: срок проверки пока не подтверждён.")
            )
        )
        assertTrue(markdown.indexOf("QA Первая реплика") < markdown.indexOf("QA Последняя реплика"))
        assertTrue(markdown.contains(markdownText("QA Сверить список проверок.")))
        assertTrue(markdown.contains(markdownText("QA Проверить чек-лист")))
        assertTrue(markdown.contains(markdownText("Не назначен")))
        assertTrue(markdown.contains(markdownText("QA Обсудили тестирование прототипа.")))
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val descriptor =
            InstrumentationRegistry.getInstrumentation()
                .uiAutomation
                .executeShellCommand("screencap -p /sdcard/Download/meet-protocol-qa-$name.png")
        val output =
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use {
                it.readText()
            }
        assertEquals("", output.trim())
    }

    private fun fixture(title: String): Meeting =
        repository.createMeeting(title, AppSettings()).also { created += it.id }

    private fun navigate(label: String) {
        compose.onNode(hasText(label) and hasClickAction()).performClick()
    }

    private fun openMeeting(meeting: Meeting) {
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(meeting.title))
        compose.onNodeWithText(meeting.title).performClick()
        val introduction = requireNotNull(repository.meeting(meeting.id)?.summary).introduction
        // Selection loads on Dispatchers.IO, then the workspace fades in. Await that visible
        // destination rather than assuming that a successful tap has completed both steps.
        compose.waitUntil(5_000) { compose.onNodeWithText(introduction).isDisplayed() }
    }

    private fun scrollTo(text: String) {
        compose.onNode(hasScrollAction()).performScrollToNode(hasText(text))
    }
}
