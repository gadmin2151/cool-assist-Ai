package cc.idomus.meetprotocol

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsScreen(vm: ProtocolViewModel, settings: AppSettings) {
    // Credentials deliberately stay out of SavedStateHandle and rememberSaveable.
    var key by remember { mutableStateOf("") }
    var summaryModel by
        rememberSaveable(settings.summaryModel) { mutableStateOf(settings.summaryModel) }
    var transcriptionModel by
        rememberSaveable(settings.transcriptionModel) {
            mutableStateOf(settings.transcriptionModel)
        }
    var language by rememberSaveable(settings.language) { mutableStateOf(settings.language) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("") }
    var resultIsError by remember { mutableStateOf(false) }
    var availableModels by remember { mutableStateOf<List<String>>(emptyList()) }
    var chooseModel by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun save(check: Boolean) {
        if (busy) return
        busy = true
        result = ""
        resultIsError = false
        scope.launch {
            try {
                val models =
                    withContext(Dispatchers.IO) {
                        val candidate =
                            if (check) key.trim().ifBlank { vm.graph.settings.readKey() } else ""
                        if (check) require(candidate.isNotBlank()) { "Сначала введите API-ключ." }
                        val models = if (check) OpenAIClient().checkKey(candidate) else emptyList()
                        vm.graph.settings.save(
                            AppSettings(
                                summaryModel.trim(),
                                transcriptionModel.trim(),
                                language.trim(),
                                settings.hasKey,
                            ),
                            newKey = key.trim().takeIf { it.isNotEmpty() },
                        )
                        vm.graph.queue.resumeAfterSettingsChange()
                        models
                    }
                if (check) availableModels = models
                key = ""
                vm.refreshSettings()
                result =
                    if (check)
                        "Ключ принят. Настройки сохранены. Доступ к конкретной модели проверяется при её использовании."
                    else "Настройки сохранены. Новые модели применятся к следующим заданиям."
            } catch (error: Exception) {
                resultIsError = true
                result = safeSettingsError(error)
            } finally {
                busy = false
            }
        }
    }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item {
            Text(
                "Всё готово к разговору",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "Один API-ключ. Без сервера и загрузки AI-моделей на телефон.",
                Modifier.padding(top = 10.dp),
                color = Muted,
            )
        }
        item {
            InfoCard {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    IconTile(Icons.Outlined.Key, AccentText)
                    Column {
                        Text(
                            "Подключение OpenAI",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            if (settings.hasKey) "Ключ сохранён на телефоне"
                            else "Добавьте свой API-ключ",
                            color = if (settings.hasKey) SoftWhite else Muted,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
                OutlinedTextField(
                    value = key,
                    onValueChange = { key = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = {
                        Text(if (settings.hasKey) "Новый ключ — для замены" else "OpenAI API key")
                    },
                    placeholder = { Text("sk-…") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions =
                        KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            autoCorrectEnabled = false,
                        ),
                    enabled = !busy,
                )
                Text(
                    "Ключ шифруется через Android Keystore. Аудио и текст отправляются напрямую в OpenAI по HTTPS. Записи остаются в библиотеке телефона.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "Нужен API-ключ с доступом к audio/transcriptions и responses. Оплата OpenAI API — отдельно от подписки ChatGPT.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedButton(
                    onClick = { save(true) },
                    enabled = !busy && (key.isNotBlank() || settings.hasKey),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Outlined.VerifiedUser, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (busy) "Проверяем…" else "Проверить и сохранить")
                }
            }
        }
        item {
            InfoCard {
                Label("РЕЗЮМЕ И ЗАДАЧИ", AccentText)
                Text(
                    "Темы, решения, ближайшие действия",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "По умолчанию gpt-5.4. Можно указать другую текстовую модель OpenAI с поддержкой Responses и Structured Outputs.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    summaryModel,
                    { summaryModel = it.take(160) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Модель резюме") },
                    singleLine = true,
                    enabled = !busy,
                )
                if (availableModels.isNotEmpty())
                    TextButton(onClick = { chooseModel = true }) {
                        Text("Выбрать из моделей аккаунта")
                    }
            }
        }
        item {
            InfoCard {
                Label("РАСПОЗНАВАНИЕ РЕЧИ", SoftWhite)
                Text(
                    "Текст по ходу встречи",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "Аудио сохраняется фрагментами по 6–14 секунд, преимущественно на паузах речи. Скорость появления текста зависит от сети и OpenAI. При потере сети запись продолжается.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "Точнее — gpt-4o-transcribe. Экономнее — gpt-4o-mini-transcribe. Уже выбранная модель сохраняется при обновлении.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = transcriptionModel == "gpt-4o-transcribe",
                        onClick = { transcriptionModel = "gpt-4o-transcribe" },
                        label = { Text("Точность") },
                        enabled = !busy,
                    )
                    FilterChip(
                        selected = transcriptionModel == "gpt-4o-mini-transcribe",
                        onClick = { transcriptionModel = "gpt-4o-mini-transcribe" },
                        label = { Text("Экономия") },
                        enabled = !busy,
                    )
                }
                OutlinedTextField(
                    transcriptionModel,
                    { transcriptionModel = it.take(160) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Модель распознавания") },
                    singleLine = true,
                    enabled = !busy,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("ru" to "Русский", "ro" to "Română", "auto" to "Авто").forEach {
                        (code, label) ->
                        FilterChip(
                            selected = language == code,
                            onClick = { language = code },
                            label = { Text(label) },
                            enabled = !busy,
                        )
                    }
                }
                OutlinedTextField(
                    language,
                    { language = it.take(8) },
                    label = { Text("Код языка: ru, ro, en или auto") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    enabled = !busy,
                )
            }
        }
        item {
            BrandButton(
                onClick = { save(false) },
                enabled = !busy && summaryModel.isNotBlank() && transcriptionModel.isNotBlank(),
                modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp),
            ) {
                Text("Сохранить настройки")
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp))
            if (result.isNotBlank())
                Text(
                    result,
                    Modifier.padding(top = 12.dp),
                    color = if (resultIsError) MaterialTheme.colorScheme.error else SoftWhite,
                )
        }
        item {
            InfoCard {
                Label("ЗАПИСЬ НА ANDROID")
                Text(
                    "Для встреч рядом с телефоном",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "Начинайте запись из приложения. Затем можно свернуть его и пользоваться уведомлением. Встречи Meet/Zoom на другом устройстве можно записывать микрофоном телефона.",
                    color = Muted,
                )
                Text(
                    "Android ограничивает захват звука звонков внутри телефона. Это приложение не записывает телефонную линию и не захватывает экран.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "AI может ошибаться. Интонация и личности говорящих автоматически не определяются. Для важных фактов используйте полную расшифровку.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        if (settings.hasKey)
            item {
                TextButton(onClick = { confirmRemove = true }, enabled = !busy) {
                    Text("Удалить API-ключ", color = MaterialTheme.colorScheme.error)
                }
            }
        item {
            Text(
                "Cool Assist Ai ${BuildConfig.VERSION_NAME} · Android\nЛокальных AI-моделей нет. Экспорт: Markdown.",
                color = Muted,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
    if (confirmRemove)
        AlertDialog(
            onDismissRequest = { confirmRemove = false },
            title = { Text("Удалить ключ OpenAI?") },
            text = {
                Text(
                    "Облачная обработка остановится. Записи и готовые результаты останутся на телефоне."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmRemove = false
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    vm.graph.settings.removeKey()
                                    vm.graph.queue.cancelAll()
                                }
                                key = ""
                                vm.refreshSettings()
                                result = "Ключ удалён"
                            } catch (_: Exception) {
                                result = "Не удалось удалить ключ. Повторите попытку."
                            }
                        }
                    }
                ) {
                    Text("Удалить")
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Отмена") } },
        )
    if (chooseModel)
        AlertDialog(
            onDismissRequest = { chooseModel = false },
            title = { Text("Модель резюме") },
            text = {
                LazyColumn(Modifier.heightIn(max = 400.dp)) {
                    availableModels
                        .filter {
                            (it.startsWith("gpt-") || it.startsWith("o3") || it.startsWith("o4")) &&
                                listOf(
                                        "audio",
                                        "transcribe",
                                        "realtime",
                                        "image",
                                        "tts",
                                        "search",
                                        "deep-research",
                                    )
                                    .none { term -> it.contains(term) }
                        }
                        .sorted()
                        .forEach { model ->
                            item {
                                TextButton(
                                    onClick = {
                                        summaryModel = model
                                        chooseModel = false
                                    },
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text(model)
                                }
                            }
                        }
                }
            },
            confirmButton = { TextButton(onClick = { chooseModel = false }) { Text("Закрыть") } },
        )
}

private fun safeSettingsError(error: Exception): String =
    when (error) {
        is ApiFailure -> error.message ?: "Не удалось подключиться к OpenAI."
        is IllegalArgumentException -> error.message ?: "Проверьте ключ и названия моделей."
        else -> "Не удалось проверить подключение. Проверьте интернет, API-ключ и доступ к OpenAI."
    }
