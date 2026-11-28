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
import kotlin.math.roundToInt

/**
 * MyDots-style push-slide drawer container shared by the QiqiWork workbench and
 * conversation screen:
 * - Pre-mounted left drawer slides with subtle `-22%` parallax underneath.
 * - Center stage pushes 1:1 with the finger and settles with spring physics.
 * - Full-screen right-swipe gesture opens the drawer from anywhere (when enabled);
 *   swipe-left, scrim tap, or system Back dismisses cleanly.
 */
@Composable
internal fun AssistantPushDrawerStage(
    open: Boolean,
    onOpenChange: (Boolean) -> Unit,
    gesturesEnabled: Boolean = true,
    drawerContent: @Composable () -> Unit,
    content: @Composable () -> Unit,
) {
    val palette = assistantPalette()
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    val progress = remember { Animatable(if (open) 1f else 0f) }
    var dragging by remember { mutableStateOf(false) }

    LaunchedEffect(open) {
        if (!dragging) {
            progress.animateTo(
                targetValue = if (open) 1f else 0f,
                animationSpec = spring(
                    dampingRatio = 0.88f,
                    stiffness = Spring.StiffnessMediumLow,
                ),
            )
        }
    }

    BackHandler(enabled = open) {
        onOpenChange(false)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.background),
    ) {
        val drawerWidthDp = minOf(306.dp, maxWidth * 0.82f)
        val drawerWidthPx = with(density) { drawerWidthDp.toPx().coerceAtLeast(1f) }
        val reveal = progress.value.coerceIn(0f, 1f)

        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(gesturesEnabled, open, drawerWidthPx) {
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
                            val current = progress.value
                            val next = (current + dragAmount / drawerWidthPx).coerceIn(0f, 1f)
                            if (open || dragAmount > 0f || current > 0f) {
                                change.consume()
                                accumulated += dragAmount
                                scope.launch { progress.snapTo(next) }
                            }
                        },
                        onDragEnd = {
                            dragging = false
                            val shouldOpen = if (open) {
                                progress.value > 0.65f && accumulated > -drawerWidthPx * 0.16f
                            } else {
                                progress.value > 0.28f || accumulated > drawerWidthPx * 0.18f
                            }
                            onOpenChange(shouldOpen)
                            scope.launch {
                                progress.animateTo(
                                    targetValue = if (shouldOpen) 1f else 0f,
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
                                    targetValue = if (open) 1f else 0f,
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
            // Left history drawer underneath with MyDots -22% parallax.
            Box(
                modifier = Modifier
                    .width(drawerWidthDp)
                    .fillMaxHeight()
                    .graphicsLayer {
                        translationX = -drawerWidthPx * 0.22f * (1f - reveal)
                        alpha = if (reveal > 0.001f) 1f else 0f
                    }
                    .background(palette.background),
            ) {
                if (reveal > 0.001f || open) {
                    drawerContent()
                }
                if (reveal < 0.999f && reveal > 0.001f) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.16f * (1f - reveal))),
                    )
                }
            }

            // Center stage pushes 1:1 with finger.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .offset { IntOffset((reveal * drawerWidthPx).roundToInt(), 0) },
            ) {
                content()

                if (reveal > 0.001f) {
                    // Hairline left edge separator between drawer and center stage.
                    Box(
                        Modifier
                            .align(Alignment.CenterStart)
                            .width(0.5.dp)
                            .fillMaxHeight()
                            .background(palette.border.copy(alpha = reveal)),
                    )
                    // Scrim over center stage; tapping closes drawer.
                    Box(
                        Modifier
                            .fillMaxSize()
                            .background(Color.Black.copy(alpha = 0.14f * reveal))
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { onOpenChange(false) },
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
    val drawerOpen = drawer.targetValue == DrawerValue.Open || drawer.currentValue == DrawerValue.Open

    AssistantPushDrawerStage(
        open = drawerOpen,
        onOpenChange = { shouldOpen ->
            scope.launch {
                if (shouldOpen) drawer.open() else drawer.close()
            }
        },
        drawerContent = {
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
        content = content,
    )
}
