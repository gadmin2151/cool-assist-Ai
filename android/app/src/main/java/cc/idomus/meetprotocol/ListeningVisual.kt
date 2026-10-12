package cc.idomus.meetprotocol

import android.animation.ValueAnimator
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas as DrawingCanvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.sqrt

/** Bounded history of measured PCM levels; it never invents motion when audio is paused. */
internal class LevelHistory(private val size: Int = 39) {
    private val values = ArrayDeque<Float>()

    init {
        require(size > 0)
    }

    fun append(level: Float, paused: Boolean): List<Float> {
        if (!paused) {
            if (values.size == size) values.removeFirst()
            values.addLast(if (level.isFinite()) sqrt(level.coerceIn(0f, 1f)) else 0f)
        }
        return List(size - values.size) { 0f } + values
    }
}

internal fun motionDuration(): Int = if (ValueAnimator.areAnimatorsEnabled()) 180 else 0

@Composable
fun ListeningPanel(
    status: CaptureStatus,
    pause: () -> Unit,
    stop: () -> Unit,
    bookmark: () -> Unit,
) {
    val history = remember(status.meetingId) { LevelHistory() }
    var levels by remember(status.meetingId) { mutableStateOf(List(39) { 0f }) }
    LaunchedEffect(status.elapsedMs, status.paused) {
        levels = history.append(status.level, status.paused)
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Surface(
            color = BrandRed.copy(alpha = .06f),
            shape = RoundedCornerShape(50.dp),
            border = BorderStroke(1.dp, BrandRed.copy(alpha = .20f)),
        ) {
            Text(
                if (status.paused) "Ⅱ НА ПАУЗЕ" else "● ИДЁТ ЗАПИСЬ",
                Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                color = AccentText,
                style = MaterialTheme.typography.labelMedium,
            )
        }
        DrawingCanvas(
            Modifier.fillMaxWidth().height(66.dp).semantics {
                contentDescription =
                    if (status.paused) "Уровень звука: пауза" else "Уровень микрофона"
            }
        ) {
            val spacing = size.width / levels.size
            val color = if (status.paused) Muted else BrandRed
            levels.forEachIndexed { index, level ->
                val height = (level * size.height * 2.4f).coerceIn(4.dp.toPx(), size.height)
                val width = (spacing * .55f).coerceAtMost(6.dp.toPx())
                val x = index * spacing + (spacing - width) / 2
                if (!status.paused && level > .02f) {
                    drawRoundRect(
                        color.copy(alpha = .04f),
                        Offset(x - 3.dp.toPx(), (size.height - height) / 2 - 4.dp.toPx()),
                        Size(width + 6.dp.toPx(), height + 8.dp.toPx()),
                        CornerRadius(8.dp.toPx()),
                    )
                }
                drawRoundRect(
                    color,
                    Offset(x, (size.height - height) / 2),
                    Size(width, height),
                    CornerRadius(width),
                )
            }
        }
        Text(
            clockText(status.elapsedMs),
            style = MaterialTheme.typography.headlineLarge,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Bold,
        )
        Text(
            if (status.warning.isNotBlank()) status.warning
            else if (status.paused) "Микрофон выключен · аудио сохранено"
            else "Слушаем · распознавание через OpenAI",
            color = if (status.warning.isBlank()) Muted else AccentText,
            style = MaterialTheme.typography.bodySmall,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(
                onClick = pause,
                modifier = Modifier.weight(1f).heightIn(min = 52.dp),
                shape = RoundedCornerShape(16.dp),
            ) {
                Icon(if (status.paused) Icons.Outlined.PlayArrow else Icons.Outlined.Pause, null)
                Spacer(Modifier.width(6.dp))
                Text(if (status.paused) "Продолжить" else "Пауза")
            }
            BrandButton(onClick = stop, modifier = Modifier.weight(1f)) {
                Icon(Icons.Outlined.Stop, null)
                Spacer(Modifier.width(6.dp))
                Text("Завершить")
            }
        }
        TextButton(onClick = bookmark, contentPadding = PaddingValues(4.dp)) {
            Icon(Icons.Outlined.BookmarkBorder, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Отметить важное")
        }
    }
}
