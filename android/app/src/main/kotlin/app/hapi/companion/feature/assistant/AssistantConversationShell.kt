package app.hapi.companion.feature.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import app.hapi.companion.di.LocalAppGraph
import app.hapi.companion.di.LocalClientProfile
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

enum class AssistantDrawerSide { None, Left, Right }

/**
 * Bidirectional MyDots-style Three-Pane Push-Slide stage:
 * - Swipe right (or tap top-left menu) -> Left History Drawer (-22% parallax)
 * - Swipe left (or tap top-right folder) -> Right Dossier / Library Drawer (+22% parallax)
 * - Center stage pushes 1:1 with finger and settles with spring physics.
 */
@Composable
internal fun AssistantPushDrawerStage(
    activeDrawer: AssistantDrawerSide,
    onActiveDrawerChange: (AssistantDrawerSide) -> Unit,
    gesturesEnabled: Boolean = true,
    hasRightDrawer: Boolean = true,
    isRightZipOpen: Boolean = false,
    onPopRightZip: () -> Unit = {},
    leftDrawerContent: @Composable () -> Unit,
    rightDrawerContent: @Composable () -> Unit = {},
    content: @Composable () -> Unit,
) {
    val palette = assistantPalette()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    // progress in [-1f, +1f]: +1f = Left drawer open, -1f = Right drawer open, 0f = closed
    val target = when (activeDrawer) {
        AssistantDrawerSide.Left -> 1f
        AssistantDrawerSide.Right -> if (hasRightDrawer) -1f else 0f
        AssistantDrawerSide.None -> 0f
    }
    val progress = remember { Animatable(target) }
    var dragging by remember { mutableStateOf(false) }

    LaunchedEffect(target) {
        if (!dragging) {
            progress.animateTo(
                targetValue = target,
                animationSpec = spring(
                    dampingRatio = 0.88f,
                    stiffness = Spring.StiffnessMediumLow,
                ),
            )
        }
    }

    BackHandler(enabled = activeDrawer != AssistantDrawerSide.None) {
        if (activeDrawer == AssistantDrawerSide.Right && isRightZipOpen) {
            onPopRightZip()
        } else {
            onActiveDrawerChange(AssistantDrawerSide.None)
        }
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.background),
    ) {
        val leftWidthDp = minOf(306.dp, maxWidth * 0.82f)
        val rightWidthDp = minOf(334.dp, maxWidth * 0.86f)
        val leftWidthPx = with(density) { leftWidthDp.toPx().coerceAtLeast(1f) }
        val rightWidthPx = with(density) { rightWidthDp.toPx().coerceAtLeast(1f) }
        val value = progress.value.coerceIn(if (hasRightDrawer) -1f else 0f, 1f)
        val leftReveal = value.coerceIn(0f, 1f)
        val rightReveal = (-value).coerceIn(0f, 1f)
        val anyReveal = maxOf(leftReveal, rightReveal)
        val centerOffsetPx = if (value >= 0f) value * leftWidthPx else value * rightWidthPx

        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(gesturesEnabled, activeDrawer, hasRightDrawer, isRightZipOpen, leftWidthPx, rightWidthPx) {
                    if (!gesturesEnabled) return@pointerInput
                    var accumulated = 0f
                    detectHorizontalDragGestures(
                        onDragStart = {
                            accumulated = 0f
                            dragging = true
                            keyboard?.hide()
                            focusManager.clearFocus(force = true)
                        },
                        onHorizontalDrag = { change, dragAmount ->
                            if (activeDrawer == AssistantDrawerSide.Right && isRightZipOpen) {
                                if (dragAmount > 0f) {
                                    change.consume()
                                    accumulated += dragAmount
                                }
                                return@detectHorizontalDragGestures
                            }
                            val current = progress.value
                            val denom = if (current > 0f || (current == 0f && dragAmount > 0f)) leftWidthPx else rightWidthPx
                            val minVal = if (hasRightDrawer && activeDrawer != AssistantDrawerSide.Left) -1f else 0f
                            val maxVal = if (activeDrawer != AssistantDrawerSide.Right) 1f else 0f
                            val next = (current + dragAmount / denom).coerceIn(minVal, maxVal)
                            if (next != current || abs(accumulated) > 0f) {
                                change.consume()
                                accumulated += dragAmount
                                scope.launch { progress.snapTo(next) }
                            }
                        },
                        onDragEnd = {
                            dragging = false
                            if (activeDrawer == AssistantDrawerSide.Right && isRightZipOpen) {
                                if (accumulated > rightWidthPx * 0.18f) {
                                    onPopRightZip()
                                }
                                return@detectHorizontalDragGestures
                            }
                            val v = progress.value
                            val nextDrawer = when (activeDrawer) {
                                AssistantDrawerSide.Left ->
                                    if (v < 0.65f || accumulated < -leftWidthPx * 0.16f) AssistantDrawerSide.None else AssistantDrawerSide.Left
                                AssistantDrawerSide.Right ->
                                    if (v > -0.65f || accumulated > rightWidthPx * 0.16f) AssistantDrawerSide.None else AssistantDrawerSide.Right
                                AssistantDrawerSide.None -> when {
                                    v > 0.26f || accumulated > leftWidthPx * 0.18f -> AssistantDrawerSide.Left
                                    hasRightDrawer && (v < -0.26f || accumulated < -rightWidthPx * 0.18f) -> AssistantDrawerSide.Right
                                    else -> AssistantDrawerSide.None
                                }
                            }
                            onActiveDrawerChange(nextDrawer)
                            val settle = when (nextDrawer) {
                                AssistantDrawerSide.Left -> 1f
                                AssistantDrawerSide.Right -> -1f
                                AssistantDrawerSide.None -> 0f
                            }
                            scope.launch {
                                progress.animateTo(
                                    targetValue = settle,
                                    animationSpec = spring(
                                        dampingRatio = 0.88f,
                                        stiffness = Spring.StiffnessMediumLow,
                                    ),
                                )
                            }
                        },
                        onDragCancel = {
                            dragging = false
                            scope.launch {
                                progress.animateTo(
                                    targetValue = target,
                                    animationSpec = spring(
                                        dampingRatio = 0.88f,
                                        stiffness = Spring.StiffnessMediumLow,
                                    ),
                                )
                            }
                        },
                    )
                },
        ) {
            // Left History Drawer (-22% parallax)
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .width(leftWidthDp)
                    .fillMaxHeight()
                    .graphicsLayer {
                        translationX = -leftWidthPx * 0.22f * (1f - leftReveal)
                        alpha = if (leftReveal > 0.001f) 1f else 0f
                    }
                    .background(palette.background),
            ) {
                if (leftReveal > 0.001f || activeDrawer == AssistantDrawerSide.Left) {
                    leftDrawerContent()
                }
                if (leftReveal < 0.999f && leftReveal > 0.001f) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.16f * (1f - leftReveal))),
                    )
                }
            }

            // Right Dossier / Library Drawer (+22% parallax)
            if (hasRightDrawer) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .width(rightWidthDp)
                        .fillMaxHeight()
                        .graphicsLayer {
                            translationX = rightWidthPx * 0.22f * (1f - rightReveal)
                            alpha = if (rightReveal > 0.001f) 1f else 0f
                        }
                        .background(palette.background),
                ) {
                    if (rightReveal > 0.001f || activeDrawer == AssistantDrawerSide.Right) {
                        rightDrawerContent()
                    }
                    if (rightReveal < 0.999f && rightReveal > 0.001f) {
                        Box(
                            Modifier
                                .fillMaxSize()
                                .background(Color.Black.copy(alpha = 0.16f * (1f - rightReveal))),
                        )
                    }
                }
            }

            // Center Stage pushes 1:1 with finger
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .offset { IntOffset(centerOffsetPx.roundToInt(), 0) },
            ) {
                content()

                if (leftReveal > 0.001f) {
                    Box(
                        Modifier
                            .align(Alignment.CenterStart)
                            .width(0.5.dp)
                            .fillMaxHeight()
                            .background(palette.border.copy(alpha = leftReveal)),
                    )
                }
                if (rightReveal > 0.001f) {
                    Box(
                        Modifier
                            .align(Alignment.CenterEnd)
                            .width(0.5.dp)
                            .fillMaxHeight()
                            .background(palette.border.copy(alpha = rightReveal)),
                    )
                }
                if (anyReveal > 0.001f) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.14f * anyReveal))
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { onActiveDrawerChange(AssistantDrawerSide.None) },
                            ),
                    )
                }
            }
        }
    }
}

@Composable
fun AssistantConversationShell(
    drawer: DrawerState,
    selectedSessionId: String? = null,
    rightDrawerOpen: Boolean = false,
    onRightDrawerChange: (Boolean) -> Unit = {},
    isRightZipOpen: Boolean = false,
    onPopRightZip: () -> Unit = {},
    rightDrawerContent: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val profile = LocalClientProfile.current
    if (profile?.mode != "assistant") {
        content()
        return
    }
    val graph = LocalAppGraph.current.activeHubGraph.collectAsState().value ?: return
    val navigation = AssistantNavigation.current
    val scope = rememberCoroutineScope()
    val leftOpen = drawer.targetValue == DrawerValue.Open || drawer.currentValue == DrawerValue.Open
    val active = when {
        rightDrawerOpen && rightDrawerContent != null -> AssistantDrawerSide.Right
        leftOpen -> AssistantDrawerSide.Left
        else -> AssistantDrawerSide.None
    }

    AssistantPushDrawerStage(
        activeDrawer = active,
        onActiveDrawerChange = { side ->
            when (side) {
                AssistantDrawerSide.Left -> {
                    onRightDrawerChange(false)
                    scope.launch { drawer.open() }
                }
                AssistantDrawerSide.Right -> {
                    scope.launch { drawer.close() }
                    onRightDrawerChange(true)
                }
                AssistantDrawerSide.None -> {
                    onRightDrawerChange(false)
                    scope.launch { drawer.close() }
                }
            }
        },
        hasRightDrawer = rightDrawerContent != null,
        isRightZipOpen = isRightZipOpen,
        onPopRightZip = onPopRightZip,
        leftDrawerContent = {
            AssistantHistoryDrawer(
                hub = graph,
                brandTitle = profile.appTitle?.takeIf { it.isNotBlank() } ?: "琪琪工作",
                selectedSessionId = selectedSessionId,
                onOpen = { id ->
                    scope.launch { drawer.close() }
                    navigation.chat(id)
                },
                onSettings = {
                    scope.launch { drawer.close() }
                    navigation.settings()
                },
                onNew = {
                    scope.launch { drawer.close() }
                    navigation.home()
                },
            )
        },
        rightDrawerContent = { rightDrawerContent?.invoke() },
        content = content,
    )
}
