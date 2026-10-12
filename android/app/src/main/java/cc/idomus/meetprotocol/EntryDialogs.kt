package cc.idomus.meetprotocol

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
fun TextEntryDialog(
    title: String,
    label: String,
    initial: String,
    confirm: String,
    description: String = "",
    dismiss: () -> Unit,
    submit: (String) -> Unit,
) {
    var value by rememberSaveable { mutableStateOf(initial) }
    EntryDialog(title, confirm, value.isNotBlank(), dismiss, { submit(value.trim()) }) {
        if (description.isNotBlank()) Text(description, color = Muted)
        OutlinedTextField(
            value = value,
            onValueChange = { value = it.take(200) },
            label = { Text(label) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
internal fun TaskEntryDialog(dismiss: () -> Unit, submit: (String, String, String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    var owner by rememberSaveable { mutableStateOf("") }
    var due by rememberSaveable { mutableStateOf("") }
    EntryDialog(
        "Новая задача",
        "Добавить",
        text.isNotBlank(),
        dismiss,
        { submit(text, owner, due) },
    ) {
        OutlinedTextField(
            text,
            { text = it.take(1000) },
            label = { Text("Что нужно сделать") },
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            owner,
            { owner = it.take(200) },
            label = { Text("Ответственный — необязательно") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            due,
            { due = it.take(200) },
            label = { Text("Срок — необязательно") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Keep actions outside the scrolling form and within the actual keyboard-safe window. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EntryDialog(
    title: String,
    confirm: String,
    enabled: Boolean,
    dismiss: () -> Unit,
    submit: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = dismiss,
        properties =
            DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(
            Modifier.fillMaxSize()
                .safeDrawingPadding()
                .imePadding()
                .padding(horizontal = 24.dp, vertical = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                modifier = Modifier.widthIn(max = 560.dp).fillMaxWidth(),
                shape = RoundedCornerShape(28.dp),
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
            ) {
                Column(Modifier.padding(24.dp)) {
                    Text(title, style = MaterialTheme.typography.headlineSmall)
                    Spacer(Modifier.height(20.dp))
                    Column(
                        Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                        content = content,
                    )
                    Spacer(Modifier.height(20.dp))
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        TextButton(onClick = dismiss) { Text("Отмена") }
                        BrandButton(onClick = submit, enabled = enabled) { Text(confirm) }
                    }
                }
            }
        }
    }
}
