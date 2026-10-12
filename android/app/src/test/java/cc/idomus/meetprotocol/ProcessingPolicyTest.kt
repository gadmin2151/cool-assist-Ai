package cc.idomus.meetprotocol

import androidx.work.ExistingWorkPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

class ProcessingPolicyTest {
    @Test
    fun `live wakeups coalesce but backlog continuation is never discarded`() {
        for (capture in listOf(CaptureState.RECORDING, CaptureState.PAUSED)) {
            assertEquals(ExistingWorkPolicy.KEEP, processingWorkPolicy(capture, false))
            assertEquals(ExistingWorkPolicy.APPEND_OR_REPLACE, processingWorkPolicy(capture, true))
        }
    }

    @Test
    fun `stop and recovery always schedule the final drain`() {
        for (capture in listOf(CaptureState.STOPPED, CaptureState.INTERRUPTED)) {
            assertEquals(ExistingWorkPolicy.APPEND_OR_REPLACE, processingWorkPolicy(capture, false))
        }
    }
}
