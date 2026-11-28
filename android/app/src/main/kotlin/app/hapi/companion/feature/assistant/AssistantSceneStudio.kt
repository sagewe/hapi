package app.hapi.companion.feature.assistant

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.hapi.protocol.wire.CaseFile
import app.hapi.protocol.wire.ClientQuickAction
import app.hapi.protocol.wire.ReferenceDoc
import app.hapi.protocol.wire.SceneDraft
import kotlinx.coroutines.launch

internal object SceneStudioPrompts {
    fun createNew(referenceDoc: ReferenceDoc? = null): String {
        val refLine = referenceDoc?.let {
            "我想基于参考底稿《${it.fileName}》（ID: ${it.id}）定制一个新场景，请先帮我梳理核查要点并生成场景草案。"
        } ?: "我想定制一个新的调查场景，请先问我 1–2 个最关键的问题，或者我直接把要求和审单表发给你。"
        return """
            【场景工坊 · 定制新场景】

            $refLine

            <scene-studio-instructions>
            你正处于「场景工坊」创造模式，面向非技术业务同事。
            1. 用简洁中文沟通，不展示代码、路径或开发术语。
            2. 如涉及稳定核查清单或固定报告格式，可在 `.gemini/skills/custom-<slug>/SKILL.md` 创建专属技能，绝不修改内置 4 个核心技能或根目录 AGENTS.md。
            3. 一旦需求明确（或在用户上传底稿/说明后），必须在回复末尾输出一个 `qiqi-scene-draft` 代码块（JSON 包含 id、title、subtitle、icon、opensAttachment、skillSlug、referenceDocIds、summaryPoints、prompt），客户端会渲染为「场景草案卡」由用户点选保存生效。
            </scene-studio-instructions>
        """.trimIndent()
    }

    fun optimize(scene: AssistantSceneSpec): String {
        val skillLine = scene.skillSlug?.let { "关联技能：$it。" }.orEmpty()
        return """
            【场景工坊 · 优化「${scene.title}」】

            我想调整「${scene.title}」这个场景的核查步骤或输出格式，请问你想怎么改？

            <scene-studio-instructions>
            当前正在优化已有场景：id=${scene.id}，title=${scene.title}，subtitle=${scene.placeholder}，icon=${scene.iconKey}，opensAttachment=${scene.opensAttachment}。$skillLine
            当前指令：
            ${scene.prompt.orEmpty()}

            请先用 2–3 条人话概括当前场景做法，询问用户希望增删或调整哪些环节。用户确认改动后，按需更新 `.gemini/skills/custom-<slug>/SKILL.md`（若为内置场景则另存为 custom-<slug> 或仅输出更新后的 `qiqi-scene-draft` 保留相同 id），并输出 `qiqi-scene-draft` 代码块供用户一键保存生效。
            </scene-studio-instructions>
        """.trimIndent()
    }

    fun promoteFromCase(caseTitle: String, caseFiles: List<CaseFile>): String {
        val fileList = caseFiles.take(8).joinToString("、") { it.fileName }
        return """
            【场景工坊 · 从本案沉淀场景】

            请结合刚才「$caseTitle」的查证步骤与交付物（${fileList.ifEmpty { "无附件" }}），提炼成一个可复用的调查场景草案。

            <scene-studio-instructions>
            用户希望把刚刚完成的合规调查「$caseTitle」的做法沉淀为一个可复用自定义场景。
            1. 提炼出通用的核查步骤、关注的风险点和交付物要求（脱敏去掉本案具体公司/自然人姓名）。
            2. 在 `.gemini/skills/custom-<slug>/SKILL.md` 写入可复用工作流（不碰内置 4 个核心技能和 AGENTS.md）。
            3. 直接在回复末尾输出一个 `qiqi-scene-draft` 代码块供用户预览并一键保存到工作台。
            </scene-studio-instructions>
        """.trimIndent()
    }
}

internal data class SceneDraftHandler(
    val onSave: suspend (SceneDraft) -> Unit,
    val onEdit: (SceneDraft) -> Unit,
)

internal val LocalSceneDraftHandler = staticCompositionLocalOf<SceneDraftHandler?> { null }

@Composable
internal fun SceneDraftCard(
    draft: SceneDraft,
    modifier: Modifier = Modifier,
) {
    val palette = assistantPalette()
    val handler = LocalSceneDraftHandler.current
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = palette.surface,
        border = BorderStroke(1.dp, palette.accentBorder),
        shadowElevation = if (palette.isDark) 4.dp else 2.dp,
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(11.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(palette.accentSoft),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = assistantSceneIcon(draft.icon),
                        contentDescription = null,
                        tint = palette.accent,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = draft.title,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                        color = palette.ink,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        if (draft.opensAttachment) {
                            DraftTagPill("自动拉起附件", accent = true)
                        }
                        if (!draft.skillSlug.isNullOrBlank()) {
                            DraftTagPill("专属工作流", accent = false)
                        }
                        if (draft.referenceDocIds.isNotEmpty()) {
                            DraftTagPill("关联 ${draft.referenceDocIds.size} 底稿", accent = false)
                        }
                    }
                }
            }

            if (draft.summaryPoints.isNotEmpty()) {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = palette.background,
                    border = BorderStroke(0.5.dp, palette.border),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(11.dp),
                        verticalArrangement = Arrangement.spacedBy(7.dp),
                    ) {
                        draft.summaryPoints.forEach { point ->
                            Row(
                                verticalAlignment = Alignment.Top,
                                horizontalArrangement = Arrangement.spacedBy(7.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .padding(top = 6.dp)
                                        .size(5.dp)
                                        .clip(CircleShape)
                                        .background(palette.accent),
                                )
                                Text(
                                    text = point,
                                    fontSize = 12.5.sp,
                                    lineHeight = 18.sp,
                                    color = palette.inkSecondary,
                                )
                            }
                        }
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(40.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(palette.accentGradient)
                        .clickable(enabled = !saving && handler != null) {
                            val h = handler ?: return@clickable
                            saving = true
                            error = null
                            scope.launch {
                                try {
                                    h.onSave(draft)
                                    saved = true
                                } catch (_: Exception) {
                                    error = "保存失败，请重试"
                                } finally {
                                    saving = false
                                }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (saving) {
                            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                        } else {
                            Icon(
                                imageVector = if (saved) Icons.Default.CheckCircle else Icons.Default.Check,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Text(
                            text = if (saved) "已保存到工作台" else "保存到工作台",
                            fontSize = 13.5.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = Color.White,
                        )
                    }
                }

                if (handler != null) {
                    Surface(
                        onClick = { handler.onEdit(draft) },
                        shape = RoundedCornerShape(12.dp),
                        color = palette.surfaceMuted,
                        border = BorderStroke(0.5.dp, palette.border),
                        modifier = Modifier.height(40.dp),
                    ) {
                        Box(
                            modifier = Modifier.padding(horizontal = 16.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text("微调", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.ink)
                        }
                    }
                }
            }

            error?.let {
                Text(it, color = palette.report, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun DraftTagPill(text: String, accent: Boolean) {
    val palette = assistantPalette()
    Text(
        text = text,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (accent) palette.accent else palette.inkMuted,
        modifier = Modifier
            .clip(CircleShape)
            .background(if (accent) palette.accentSoft else palette.surfaceMuted)
            .padding(horizontal = 6.5.dp, vertical = 2.dp),
    )
}

@Composable
internal fun ScenarioEditorDialog(
    initial: ClientQuickAction,
    onDismiss: () -> Unit,
    onSave: suspend (ClientQuickAction) -> Unit,
) {
    val palette = assistantPalette()
    val scope = rememberCoroutineScope()
    var title by remember(initial) { mutableStateOf(initial.title) }
    var subtitle by remember(initial) { mutableStateOf(initial.subtitle.orEmpty()) }
    var iconKey by remember(initial) { mutableStateOf(initial.icon ?: "checklist") }
    var opensAttachment by remember(initial) { mutableStateOf(initial.opensAttachment ?: false) }
    var prompt by remember(initial) { mutableStateOf(initial.prompt) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("编辑场景", fontWeight = FontWeight.Bold) },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("场景名称") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = subtitle,
                    onValueChange = { subtitle = it },
                    label = { Text("输入框提示语（可选）") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("选中时自动拉起附件", fontSize = 14.sp, color = palette.ink)
                    Switch(checked = opensAttachment, onCheckedChange = { opensAttachment = it })
                }
                Text("图标", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = palette.inkMuted)
                assistantCuratedIcons.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                        row.forEach { choice ->
                            val active = iconKey == choice.key
                            Surface(
                                onClick = { iconKey = choice.key },
                                shape = RoundedCornerShape(10.dp),
                                color = if (active) palette.accentSoft else palette.surfaceMuted,
                                border = if (active) BorderStroke(1.dp, palette.accent) else null,
                                modifier = Modifier.weight(1f),
                            ) {
                                Column(
                                    modifier = Modifier.padding(vertical = 8.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(3.dp),
                                ) {
                                    Icon(choice.icon, null, tint = if (active) palette.accent else palette.inkSecondary, modifier = Modifier.size(18.dp))
                                    Text(choice.label, fontSize = 10.sp, color = if (active) palette.accent else palette.inkSecondary)
                                }
                            }
                        }
                    }
                }
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { prompt = it },
                    label = { Text("调查要求（人话即可）") },
                    minLines = 3,
                    maxLines = 6,
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = palette.report, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving,
                onClick = {
                    val clean = title.trim()
                    if (clean.isEmpty()) {
                        error = "请填写场景名称"
                        return@TextButton
                    }
                    saving = true
                    error = null
                    scope.launch {
                        try {
                            onSave(
                                initial.copy(
                                    title = clean,
                                    subtitle = subtitle.trim().ifEmpty { null },
                                    icon = iconKey,
                                    opensAttachment = opensAttachment,
                                    prompt = prompt.trim(),
                                    hidden = false,
                                ),
                            )
                            onDismiss()
                        } catch (_: Exception) {
                            error = "保存失败，请重试"
                        } finally {
                            saving = false
                        }
                    }
                },
            ) {
                Text(if (saving) "保存中…" else "保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}
