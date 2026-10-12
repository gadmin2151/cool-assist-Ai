package cc.idomus.meetprotocol

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProtocolApp(vm: ProtocolViewModel) {
    val data by vm.workspace.collectAsStateWithLifecycle()
    val page by vm.page.collectAsStateWithLifecycle()
    val capture by CaptureController.status.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    val startupError by vm.graph.startupError.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var newMeeting by rememberSaveable { mutableStateOf(false) }
    var pendingTitle by rememberSaveable { mutableStateOf("") }
    var exportId by rememberSaveable { mutableStateOf<String?>(null) }
    var deleteId by rememberSaveable { mutableStateOf<String?>(null) }
    var renameId by rememberSaveable { mutableStateOf<String?>(null) }
    var permissionDenied by rememberSaveable { mutableStateOf(false) }
    val permissions =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            result ->
            val granted =
                result[Manifest.permission.RECORD_AUDIO] == true ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED
            if (granted) vm.createAndRecord(context, pendingTitle) else permissionDenied = true
        }
    val saveDocument =
        rememberLauncherForActivityResult(
            ActivityResultContracts.CreateDocument("text/markdown")
        ) { uri ->
            val id = exportId
            if (uri != null && id != null) {
                scope.launch {
                    try {
                        val markdown = vm.markdown(id)
                        withContext(Dispatchers.IO) {
                            checkNotNull(context.contentResolver.openOutputStream(uri, "wt"))
                                .bufferedWriter()
                                .use { it.write(markdown) }
                        }
                        vm.message("Markdown сохранён")
                    } catch (_: Exception) {
                        vm.message("Не удалось сохранить файл. Выберите другое место.")
                    }
                }
            }
            exportId = null
        }
    fun export(meeting: Meeting) {
        exportId = meeting.id
        saveDocument.launch("${safeFilename(meeting.title)}.md")
    }
    fun share(meeting: Meeting) {
        scope.launch {
            try {
                val markdown = vm.markdown(meeting.id)
                val file =
                    withContext(Dispatchers.IO) {
                        val directory = File(context.cacheDir, "exports").apply { mkdirs() }
                        directory
                            .listFiles()
                            ?.filter { System.currentTimeMillis() - it.lastModified() > 86400000 }
                            ?.forEach { it.delete() }
                        File(directory, "${safeFilename(meeting.title)}-${meeting.id.take(8)}.md")
                            .apply { writeText(markdown) }
                    }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                context.startActivity(
                    Intent.createChooser(
                        Intent(Intent.ACTION_SEND).apply {
                            type = "text/markdown"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        },
                        "Поделиться протоколом",
                    )
                )
            } catch (_: Exception) {
                vm.message("Не удалось подготовить файл для отправки.")
            }
        }
    }
    LaunchedEffect(vm) { vm.messages.collect { snackbar.showSnackbar(it) } }
    // A confirmation from the previous screen must not cover the next navigation target.
    LaunchedEffect(page, data.selected?.id) { snackbar.currentSnackbarData?.dismiss() }
    LaunchedEffect(capture.meetingId, capture.warning) {
        if (capture.meetingId == null && capture.warning.isNotBlank())
            snackbar.showSnackbar(capture.warning)
    }
    BackHandler(enabled = data.selected != null || page != "library") { vm.navigate("library") }

    Scaffold(
        containerColor = Canvas,
        snackbarHost = {
            SnackbarHost(snackbar) { message ->
                Snackbar(
                    message,
                    containerColor = RaisedPanel,
                    contentColor = SoftWhite,
                    actionColor = AccentText,
                    dismissActionContentColor = Muted,
                    shape = RoundedCornerShape(16.dp),
                )
            }
        },
        topBar = {
            TopAppBar(
                title = {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            painterResource(R.drawable.ic_launcher),
                            null,
                            Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)),
                            tint = Color.Unspecified,
                        )
                        Text("Cool Assist Ai", fontWeight = FontWeight.Bold)
                    }
                },
                navigationIcon = {
                    if (data.selected != null && page == "library")
                        IconButton(onClick = { vm.select(null) }) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, "К библиотеке")
                        }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NavigationSurface),
            )
        },
        bottomBar = {
            Column {
                if (
                    capture.meetingId != null &&
                        (data.selected?.id != capture.meetingId || page != "library")
                )
                    ActiveRecordingBar(
                        capture,
                        data.meetings.firstOrNull { it.id == capture.meetingId }?.title
                            ?: "Запись встречи",
                        open = { vm.select(capture.meetingId) },
                        pause = {
                            if (capture.paused) CaptureController.resume(context)
                            else CaptureController.pause(context)
                        },
                        stop = { CaptureController.stop(context) },
                    )
                NavigationBar(containerColor = NavigationSurface) {
                    listOf(
                            Triple("library", "Встречи", Icons.Outlined.FolderOpen),
                            Triple("tasks", "Задачи", Icons.Outlined.Checklist),
                            Triple("settings", "Настройки", Icons.Outlined.Tune),
                        )
                        .forEach { (id, label, icon) ->
                            NavigationBarItem(
                                selected = page == id,
                                onClick = { vm.navigate(id) },
                                icon = { Icon(icon, label) },
                                label = { Text(label) },
                                colors =
                                    NavigationBarItemDefaults.colors(
                                        selectedIconColor = BrandRed,
                                        selectedTextColor = SoftWhite,
                                        indicatorColor = BrandRed.copy(alpha = .08f),
                                        unselectedIconColor = Muted,
                                        unselectedTextColor = Muted,
                                    ),
                            )
                        }
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            val destination =
                when {
                    page != "library" -> page
                    data.selected != null -> "meeting"
                    else -> "library"
                }
            Crossfade(
                targetState = destination,
                animationSpec = tween(motionDuration()),
                label = "workspace",
            ) { route ->
                when {
                    startupError.isNotBlank() ->
                        EmptyPanel(
                            Icons.Outlined.ErrorOutline,
                            "Библиотека недоступна",
                            startupError,
                        )
                    !data.ready -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                    route == "settings" -> SettingsScreen(vm, data.settings)
                    route == "tasks" -> TasksScreen(data, vm)
                    route == "meeting" && data.selected != null ->
                        MeetingScreen(
                            data,
                            capture,
                            vm,
                            export = { export(data.selected!!) },
                            share = { share(data.selected!!) },
                            rename = { renameId = data.selected!!.id },
                            delete = { deleteId = data.selected!!.id },
                        )
                    else ->
                        LibraryScreen(
                            data,
                            capture,
                            busy,
                            onNew = { newMeeting = true },
                            onSelect = vm::select,
                            onSettings = { vm.navigate("settings") },
                        )
                }
            }
        }
    }
    if (newMeeting)
        TextEntryDialog(
            title = "Новая встреча",
            label = "Название",
            initial = "Встреча ${shortDate(System.currentTimeMillis())}",
            confirm = "Начать запись",
            description =
                "Микрофон записывает звук вокруг телефона. Аудио отправляется в OpenAI для расшифровки. Предупредите участников о записи.",
            dismiss = { newMeeting = false },
            submit = { title ->
                newMeeting = false
                pendingTitle = title
                val requested = mutableListOf(Manifest.permission.RECORD_AUDIO)
                if (Build.VERSION.SDK_INT >= 33) requested += Manifest.permission.POST_NOTIFICATIONS
                permissions.launch(requested.toTypedArray())
            },
        )
    if (permissionDenied) {
        AlertDialog(
            onDismissRequest = { permissionDenied = false },
            title = { Text("Нужен доступ к микрофону") },
            text = {
                Text(
                    "Разрешите микрофон в настройках Android, затем снова нажмите «Записать встречу»."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        permissionDenied = false
                        context.startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${context.packageName}"),
                            )
                        )
                    }
                ) {
                    Text("Открыть настройки")
                }
            },
            dismissButton = { TextButton(onClick = { permissionDenied = false }) { Text("Позже") } },
        )
    }
    deleteId?.let { id ->
        AlertDialog(
            onDismissRequest = { deleteId = null },
            title = { Text("Удалить встречу?") },
            text = {
                Text(
                    "Аудио, расшифровка, резюме и задачи этой встречи будут удалены с телефона. Сохранённые вами Markdown-файлы останутся."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteId = null
                        vm.delete(id)
                    }
                ) {
                    Text("Удалить", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deleteId = null }) { Text("Отмена") } },
        )
    }
    renameId?.let { id ->
        TextEntryDialog(
            "Название встречи",
            "Название",
            data.meetings.firstOrNull { it.id == id }?.title.orEmpty(),
            "Сохранить",
            dismiss = { renameId = null },
            submit = {
                vm.rename(id, it)
                renameId = null
            },
        )
    }
}

@Composable
private fun LibraryScreen(
    data: Workspace,
    capture: CaptureStatus,
    busy: Boolean,
    onNew: () -> Unit,
    onSelect: (String) -> Unit,
    onSettings: () -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    val filtered = data.meetings.filter { it.title.contains(query, true) }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Column(
                Modifier.fillMaxWidth()
                    .background(
                        Brush.linearGradient(listOf(RaisedPanel, Panel)),
                        RoundedCornerShape(28.dp),
                    )
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Label("ОТ РАЗГОВОРА К ДЕЙСТВИЮ", AccentText)
                Text(
                    "Слушайте.\nВажное останется.",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text("Речь → текст → резюме и задачи.\nВся AI-обработка — в OpenAI.", color = Muted)
                BrandButton(
                    onClick = onNew,
                    enabled = capture.meetingId == null && !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp),
                ) {
                    Icon(Icons.Outlined.Mic, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (busy) "Подготовка…" else "Записать встречу")
                }
                if (capture.meetingId != null)
                    Text(
                        "Запись уже идёт. Можно открыть любую встречу ниже.",
                        color = SoftWhite,
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
        }
        if (!data.settings.hasKey)
            item {
                Surface(
                    onClick = onSettings,
                    shape = RoundedCornerShape(20.dp),
                    color = Panel,
                    border = BorderStroke(1.dp, AccentText.copy(alpha = .35f)),
                ) {
                    Row(
                        Modifier.padding(18.dp),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Outlined.Key, null, tint = AccentText)
                        Column(Modifier.weight(1f)) {
                            Text("Подключите OpenAI", fontWeight = FontWeight.SemiBold)
                            Text(
                                "Введите API-ключ один раз. Без ключа доступна запись аудио.",
                                color = Muted,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        Icon(Icons.Outlined.ChevronRight, "Открыть настройки")
                    }
                }
            }
        item {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Ваши встречи",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                Badge(containerColor = Panel, contentColor = SoftWhite) {
                    Text(data.meetings.size.toString(), Modifier.padding(4.dp))
                }
            }
        }
        if (data.meetings.isNotEmpty())
            item {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("Найти встречу") },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) },
                    shape = RoundedCornerShape(16.dp),
                )
            }
        if (filtered.isEmpty())
            item {
                EmptyPanel(
                    Icons.Outlined.FolderOpen,
                    if (query.isBlank()) "Здесь начинается ваша библиотека"
                    else "Ничего не найдено",
                    if (query.isBlank())
                        "Запишите первую встречу. Текст будет появляться по ходу разговора, а резюме — после завершения."
                    else "Попробуйте другое название.",
                )
            }
        items(filtered, key = { it.id }) { meeting ->
            Surface(
                onClick = { onSelect(meeting.id) },
                color = Panel,
                shape = RoundedCornerShape(22.dp),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(18.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconTile(
                        if (meeting.capture == CaptureState.RECORDING) Icons.Outlined.GraphicEq
                        else Icons.AutoMirrored.Outlined.Notes,
                        if (meeting.summary != null) AccentText else SoftWhite,
                    )
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Text(
                            meeting.title,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            "${shortDate(meeting.createdAt)}  ·  ${clockText(meeting.durationMs)}",
                            color = Muted,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Text(
                            statusText(meeting),
                            color = statusColor(meeting),
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                    Icon(Icons.Outlined.ChevronRight, null, tint = Muted)
                }
            }
        }
        item {
            Text(
                "Записи хранятся на этом телефоне. Экспортируйте важные встречи в Markdown.",
                color = Muted,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun ActiveRecordingBar(
    status: CaptureStatus,
    title: String,
    open: () -> Unit,
    pause: () -> Unit,
    stop: () -> Unit,
) {
    Surface(
        Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        color = RaisedPanel,
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, AccentText.copy(alpha = .3f)),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).clickable(onClick = open).padding(vertical = 12.dp)) {
                Text(
                    if (status.paused) "ПАУЗА · ${clockText(status.elapsedMs)}"
                    else "● ЗАПИСЬ · ${clockText(status.elapsedMs)}",
                    color = AccentText,
                    style = MaterialTheme.typography.labelMedium,
                )
                Text(
                    title,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            IconButton(onClick = pause) {
                Icon(
                    if (status.paused) Icons.Outlined.PlayArrow else Icons.Outlined.Pause,
                    if (status.paused) "Продолжить запись" else "Приостановить запись",
                )
            }
            IconButton(onClick = stop) {
                Icon(
                    Icons.Outlined.StopCircle,
                    "Завершить запись",
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun MeetingScreen(
    data: Workspace,
    capture: CaptureStatus,
    vm: ProtocolViewModel,
    export: () -> Unit,
    share: () -> Unit,
    rename: () -> Unit,
    delete: () -> Unit,
) {
    val meeting = requireNotNull(data.selected)
    var tab by
        rememberSaveable(meeting.id) { mutableIntStateOf(if (meeting.summary == null) 1 else 0) }
    var menu by remember { mutableStateOf(false) }
    val active = capture.meetingId == meeting.id
    val context = LocalContext.current
    var sourceIndex by rememberSaveable(meeting.id) { mutableStateOf<Int?>(null) }
    Column {
        Text(
            meeting.title,
            Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "${shortDate(meeting.createdAt)} · ${clockText(if (active) capture.elapsedMs else meeting.durationMs)}",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    statusText(meeting),
                    color = statusColor(meeting),
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            IconButton(onClick = export) {
                Icon(Icons.Outlined.FileDownload, "Сохранить Markdown", tint = AccentText)
            }
            IconButton(onClick = share) { Icon(Icons.Outlined.Share, "Поделиться Markdown") }
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Outlined.MoreVert, "Действия со встречей")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text("Переименовать") },
                        onClick = {
                            menu = false
                            rename()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Повторить обработку") },
                        onClick = {
                            menu = false
                            vm.retry(meeting.id)
                        },
                    )
                    if (
                        !active &&
                            meeting.processing in
                                listOf(ProcessState.TRANSCRIBING, ProcessState.SUMMARIZING)
                    ) {
                        DropdownMenuItem(
                            text = { Text("Приостановить обработку") },
                            onClick = {
                                menu = false
                                vm.cancelProcessing(meeting.id)
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Удалить встречу", color = MaterialTheme.colorScheme.error) },
                        enabled =
                            !active &&
                                meeting.capture !in
                                    listOf(CaptureState.RECORDING, CaptureState.PAUSED),
                        onClick = {
                            menu = false
                            delete()
                        },
                    )
                }
            }
        }
        if (active)
            ListeningPanel(
                capture,
                pause = {
                    if (capture.paused) CaptureController.resume(context)
                    else CaptureController.pause(context)
                },
                stop = { CaptureController.stop(context) },
                bookmark = { vm.bookmark(meeting.id, capture.elapsedMs) },
            )
        if (meeting.error.isNotBlank())
            Surface(
                Modifier.fillMaxWidth().padding(16.dp),
                color = RaisedPanel,
                shape = RoundedCornerShape(16.dp),
            ) {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        meeting.error,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    TextButton(onClick = { vm.retry(meeting.id) }) { Text("Повторить") }
                }
            }
        TabRow(selectedTabIndex = tab, containerColor = Canvas) {
            listOf("Резюме", "Текст", "Заметки").forEachIndexed { index, label ->
                Tab(selected = tab == index, onClick = { tab = index }, text = { Text(label) })
            }
        }
        when (tab) {
            0 ->
                BriefScreen(
                    meeting,
                    data.segments,
                    data.tasks.filter { it.meetingId == meeting.id },
                    vm,
                    onSource = {
                        sourceIndex = it
                        tab = 1
                    },
                )
            1 -> TranscriptScreen(data.segments, active, sourceIndex)
            else -> NotesScreen(meeting, data.tasks.filter { it.meetingId == meeting.id }, vm)
        }
    }
}

@Composable
private fun BriefScreen(
    meeting: Meeting,
    segments: List<Segment>,
    tasks: List<MeetingTask>,
    vm: ProtocolViewModel,
    onSource: (Int) -> Unit,
) {
    val brief = meeting.summary
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (brief == null) {
            item {
                EmptyPanel(
                    Icons.Outlined.AutoAwesome,
                    if (meeting.processing == ProcessState.SUMMARIZING) "Собираем главное"
                    else "Из разговора — в ясный протокол",
                    if (meeting.capture in listOf(CaptureState.RECORDING, CaptureState.PAUSED))
                        "Резюме появится после завершения. Расшифровка уже доступна на вкладке «Текст»."
                    else if (meeting.processing == ProcessState.SUMMARIZING)
                        "OpenAI выделяет темы, решения, ближайшие действия и открытые вопросы. Можно работать с другими встречами."
                    else "После распознавания здесь будут темы, решения и ближайшие действия.",
                )
            }
        } else {
            item { Label("РЕЗЮМЕ ВСТРЕЧИ", AccentText) }
            item { Text(brief.introduction, style = MaterialTheme.typography.titleMedium) }
            items(brief.points) { point ->
                InfoCard {
                    Text(point.topic, fontWeight = FontWeight.Bold, color = AccentText)
                    Text(point.text)
                    SourceLinks(point.sources, segments, onSource)
                }
            }
            if (brief.decisions.isNotEmpty()) {
                item { Label("РЕШЕНИЯ", SoftWhite) }
                items(brief.decisions) { Text("• $it", style = MaterialTheme.typography.bodyLarge) }
            }
            if (brief.actions.isNotEmpty()) {
                item { Label("БЛИЖАЙШИЕ ДЕЙСТВИЯ", AccentText) }
                items(brief.actions) { action ->
                    val added =
                        tasks.any {
                            it.text == action.text &&
                                it.owner == action.owner &&
                                it.due == action.due
                        }
                    InfoCard {
                        Text(action.text, fontWeight = FontWeight.Medium)
                        Text(
                            listOf(
                                    action.owner.ifBlank { "Ответственный не указан" },
                                    action.due.ifBlank { "Срок не указан" },
                                )
                                .joinToString(" · "),
                            color = Muted,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        SourceLinks(action.sources, segments, onSource)
                        TextButton(
                            onClick = {
                                vm.addTask(meeting.id, action.text, action.owner, action.due)
                            },
                            enabled = !added,
                            contentPadding = PaddingValues(0.dp),
                        ) {
                            Icon(
                                if (added) Icons.Outlined.TaskAlt else Icons.Outlined.AddTask,
                                null,
                                Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(if (added) "Добавлено в задачи" else "Добавить в задачи")
                        }
                    }
                }
            }
            if (brief.questions.isNotEmpty()) {
                item { Label("ОСТАЛОСЬ УТОЧНИТЬ", AccentText) }
                items(brief.questions) { Text("• $it") }
            }
            item {
                Text(
                    "Резюме: ${meeting.generatedSummaryModel ?: meeting.summaryModel}. Проверяйте важные договорённости по полному тексту встречи.",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        if (meeting.capture !in listOf(CaptureState.RECORDING, CaptureState.PAUSED))
            item {
                BrandButton(
                    onClick = { vm.summary(meeting.id) },
                    enabled =
                        segments.isNotEmpty() &&
                            meeting.processing != ProcessState.SUMMARIZING &&
                            !meeting.summaryRequested,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Outlined.AutoAwesome, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (brief == null) "Создать резюме" else "Обновить резюме")
                }
                if (meeting.processing == ProcessState.TRANSCRIBING || meeting.summaryRequested)
                    Text(
                        "Сначала завершим расшифровку всех фрагментов. Затем будет готово резюме.",
                        Modifier.padding(top = 8.dp),
                        color = Muted,
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
    }
}

@Composable
private fun TranscriptScreen(segments: List<Segment>, active: Boolean, sourceIndex: Int? = null) {
    val listState = rememberLazyListState()
    var followLive by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(sourceIndex) {
        sourceIndex?.let { source ->
            val position = segments.indexOfFirst { it.index == source }
            if (position >= 0) {
                followLive = false
                listState.scrollToItem(position + 1)
            }
        }
    }
    LaunchedEffect(segments.lastOrNull(), active, followLive) {
        if (active && followLive && segments.isNotEmpty())
            if (motionDuration() == 0) listState.scrollToItem(segments.size)
            else listState.animateScrollToItem(segments.size)
    }
    Column {
        if (active)
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "К последним репликам",
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
                Switch(checked = followLive, onCheckedChange = { followLive = it })
            }
        LazyColumn(
            Modifier.fillMaxSize(),
            state = listState,
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                Text(
                    "ПОЛНАЯ РАСШИФРОВКА",
                    color = SoftWhite,
                    style = MaterialTheme.typography.labelLarge,
                )
                Text(
                    "${segments.count { it.state == SegmentState.DONE }} из ${segments.size} фрагментов распознано. Время соответствует аудиофрагментам.",
                    Modifier.padding(top = 8.dp),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (segments.isEmpty())
                item {
                    EmptyPanel(
                        Icons.Outlined.GraphicEq,
                        if (active) "Слушаем встречу" else "Текст пока не готов",
                        if (active)
                            "Первые строки появятся после записи и отправки первого фрагмента. При отсутствии сети аудио останется в очереди."
                        else "После записи и обработки здесь появится полный текст.",
                    )
                }
            items(segments, key = { it.id }) { segment ->
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        "${clockText(segment.startMs)} — ${clockText(segment.endMs)}",
                        color = SoftWhite,
                        style = MaterialTheme.typography.labelMedium,
                    )
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        Text(
                            if (segment.state == SegmentState.PENDING) "Ожидает распознавания…"
                            else segment.text.ifBlank { "[Речь не обнаружена]" },
                            color =
                                if (segment.state == SegmentState.PENDING) Muted
                                else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    HorizontalDivider(
                        Modifier.padding(top = 10.dp),
                        color = Muted.copy(alpha = .1f),
                    )
                }
            }
        }
    }
}

@Composable
private fun NotesScreen(meeting: Meeting, tasks: List<MeetingTask>, vm: ProtocolViewModel) {
    var notes by rememberSaveable(meeting.id, meeting.notes) { mutableStateOf(meeting.notes) }
    var taskDialog by rememberSaveable { mutableStateOf(false) }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text(
                "Ваши заметки",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "Добавьте контекст, формулировки и уточнения. Они сохраняются отдельно от расшифровки.",
                Modifier.padding(top = 8.dp),
                color = Muted,
            )
        }
        item {
            OutlinedTextField(
                value = notes,
                onValueChange = { if (it.length <= 50000) notes = it },
                modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp),
                label = { Text("Заметки к встрече") },
                shape = RoundedCornerShape(18.dp),
            )
            BrandButton(
                onClick = { vm.notes(meeting.id, notes) },
                enabled = notes != meeting.notes,
                modifier = Modifier.padding(top = 8.dp),
            ) {
                Text("Сохранить заметки")
            }
        }
        item {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Задачи встречи",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                TextButton(onClick = { taskDialog = true }) { Text("Добавить") }
            }
        }
        items(tasks, key = { it.id }) { TaskCard(it, null, vm) }
        if (tasks.isEmpty())
            item { Text("Добавьте задачу вручную или выберите действие из резюме.", color = Muted) }
    }
    if (taskDialog)
        TaskEntryDialog(
            dismiss = { taskDialog = false },
            submit = { text, owner, due ->
                vm.addTask(meeting.id, text, owner, due)
                taskDialog = false
            },
        )
}

@Composable
private fun TasksScreen(data: Workspace, vm: ProtocolViewModel) {
    var showCompleted by rememberSaveable { mutableStateOf(false) }
    val tasks = data.tasks.filter { it.done == showCompleted }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(
                "От слов — к делам",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
        }
        item {
            Text(
                "Задачи из всех встреч в одном месте. Добавляйте подтверждённые действия из резюме.",
                color = Muted,
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = !showCompleted,
                    onClick = { showCompleted = false },
                    label = { Text("В работе · ${data.tasks.count { !it.done }}") },
                )
                FilterChip(
                    selected = showCompleted,
                    onClick = { showCompleted = true },
                    label = { Text("Готово · ${data.tasks.count { it.done }}") },
                )
            }
        }
        if (tasks.isEmpty())
            item {
                EmptyPanel(
                    Icons.Outlined.TaskAlt,
                    if (showCompleted) "Завершённых задач пока нет" else "Всё под контролем",
                    "Задачи появятся после добавления из встречи. Ни одно действие AI не создаётся без вашего нажатия.",
                )
            }
        items(tasks, key = { it.id }) { task ->
            TaskCard(task, data.meetings.firstOrNull { it.id == task.meetingId }?.title, vm)
        }
    }
}

@Composable
private fun TaskCard(task: MeetingTask, meetingTitle: String?, vm: ProtocolViewModel) {
    InfoCard {
        Row(verticalAlignment = Alignment.Top) {
            Checkbox(checked = task.done, onCheckedChange = { vm.toggleTask(task) })
            Column(
                Modifier.weight(1f).padding(top = 10.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(task.text, fontWeight = FontWeight.Medium)
                if (task.owner.isNotBlank() || task.due.isNotBlank())
                    Text(
                        listOf(task.owner, task.due).filter { it.isNotBlank() }.joinToString(" · "),
                        color = Muted,
                        style = MaterialTheme.typography.bodySmall,
                    )
            }
            IconButton(onClick = { vm.deleteTask(task.id) }) {
                Icon(
                    Icons.Outlined.Close,
                    "Удалить задачу",
                    tint = Muted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        if (meetingTitle != null)
            TextButton(onClick = { vm.select(task.meetingId) }) {
                Text(meetingTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
    }
}

@Composable
fun InfoCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        Modifier.fillMaxWidth(),
        color = Panel,
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, Outline),
    ) {
        Column(
            Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    }
}

@Composable
fun Label(text: String, color: Color = Muted) {
    Text(
        text,
        color = color,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.Bold,
    )
}

@Composable
fun IconTile(icon: ImageVector, color: Color) {
    Box(
        Modifier.size(48.dp).background(color.copy(alpha = .1f), RoundedCornerShape(15.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = color)
    }
}

@Composable
fun EmptyPanel(icon: ImageVector, title: String, subtitle: String) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        IconTile(icon, SoftWhite)
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Text(subtitle, color = Muted)
    }
}

fun shortDate(timestamp: Long): String =
    SimpleDateFormat("d MMM · HH:mm", Locale("ru")).format(Date(timestamp))

fun safeFilename(value: String): String =
    value.replace(Regex("[^\\p{L}\\p{N} ._-]"), "_").trim().take(80).ifBlank { "Cool Assist Ai" }

fun statusText(meeting: Meeting): String =
    when {
        meeting.capture == CaptureState.RECORDING -> "Идёт запись"
        meeting.capture == CaptureState.PAUSED -> "Запись на паузе"
        meeting.processing == ProcessState.ERROR -> "Нужно внимание"
        meeting.processing == ProcessState.SUMMARIZING -> "Создаём резюме"
        meeting.processing == ProcessState.TRANSCRIBING -> "Распознаём речь"
        meeting.capture == CaptureState.INTERRUPTED -> "Запись прервалась · аудио сохранено"
        meeting.summary != null -> "Готово"
        meeting.summaryRequested -> "В очереди на обработку"
        else -> "Сохранено на телефоне"
    }

fun statusColor(meeting: Meeting): Color =
    when {
        meeting.processing == ProcessState.ERROR || meeting.capture == CaptureState.INTERRUPTED ->
            Color(0xFFFFBD91)
        meeting.capture in listOf(CaptureState.RECORDING, CaptureState.PAUSED) -> AccentText
        meeting.summary != null -> SoftWhite
        else -> AccentText
    }

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SourceLinks(sources: List<Int>, segments: List<Segment>, onSource: (Int) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        sources.forEach { index ->
            segments
                .firstOrNull { it.index == index }
                ?.let { segment ->
                    TextButton(
                        onClick = { onSource(index) },
                        contentPadding = PaddingValues(horizontal = 4.dp),
                    ) {
                        Icon(Icons.Outlined.Link, null, Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(
                            clockText(segment.startMs),
                            style = MaterialTheme.typography.labelMedium,
                        )
                    }
                }
        }
    }
}
