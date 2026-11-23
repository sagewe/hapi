package app.hapi.companion.feature.assistant
import androidx.compose.runtime.staticCompositionLocalOf
data class AssistantNavigationActions(val home: () -> Unit = {}, val settings: () -> Unit = {}, val pair: () -> Unit = {}, val chat: (String) -> Unit = {})
val AssistantNavigation = staticCompositionLocalOf { AssistantNavigationActions() }
