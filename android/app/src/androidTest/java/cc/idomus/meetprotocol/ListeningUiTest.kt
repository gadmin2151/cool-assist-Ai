package cc.idomus.meetprotocol

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

/** Synthetic input levels only: these tests never open the microphone or contact OpenAI. */
class ListeningUiTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun controlsRemainUsableWhenPausedAndBookmarkRequiresAnExplicitClick() {
        val paused = mutableStateOf(false)
        var stops = 0
        var bookmarks = 0
        compose.setContent {
            MeetProtocolTheme {
                ListeningPanel(
                    CaptureStatus("fixture", paused.value, 65_000, .15f),
                    pause = { paused.value = !paused.value },
                    stop = { stops++ },
                    bookmark = { bookmarks++ },
                )
            }
        }
        compose.onNodeWithText("01:05").assertIsDisplayed()
        compose.onNodeWithContentDescription("Уровень микрофона").assertIsDisplayed()
        assertEquals(0, bookmarks)
        compose.onNodeWithText("Отметить важное").performClick()
        assertEquals(1, bookmarks)
        compose.onNodeWithText("Пауза").performClick()
        compose.onNodeWithContentDescription("Уровень звука: пауза").assertIsDisplayed()
        compose.onNodeWithText("Продолжить").performClick()
        compose.onNodeWithContentDescription("Уровень микрофона").assertIsDisplayed()
        compose.onNodeWithText("Завершить").performClick()
        assertEquals(1, stops)
    }
}
