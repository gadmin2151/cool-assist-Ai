package cc.idomus.meetprotocol

import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

val BrandRed = Color(0xFFD60000)
// Secondary controls stay neutral; recording and the main action carry the red accent.
val AccentText = Color(0xFFD3D3D9)
val SoftWhite = Color(0xFFF5F5F7)
val Canvas = Color(0xFF202123)
val NavigationSurface = Color(0xFF191A1D)
val Panel = Color(0xFF2A2B2F)
val RaisedPanel = Color(0xFF323338)
val Muted = Color(0xFFA8A8B2)
val Outline = Color(0xFF414248)

@Composable
fun MeetProtocolTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme =
            darkColorScheme(
                primary = AccentText,
                onPrimary = Canvas,
                primaryContainer = RaisedPanel,
                onPrimaryContainer = SoftWhite,
                secondary = SoftWhite,
                tertiary = AccentText,
                background = Canvas,
                onBackground = SoftWhite,
                surface = Panel,
                onSurface = SoftWhite,
                surfaceVariant = RaisedPanel,
                onSurfaceVariant = Muted,
                outline = Outline,
                error = Color(0xFFFFB4A9),
            ),
        shapes =
            Shapes(
                small = RoundedCornerShape(12.dp),
                medium = RoundedCornerShape(18.dp),
                large = RoundedCornerShape(24.dp),
            ),
        typography = Typography(),
        content = content,
    )
}

@Composable
fun BrandButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    Button(
        onClick,
        modifier.heightIn(min = 52.dp),
        enabled,
        shape = RoundedCornerShape(16.dp),
        colors = ButtonDefaults.buttonColors(containerColor = BrandRed, contentColor = SoftWhite),
        content = content,
    )
}
