package app.hapi.protocol.wire
import kotlinx.serialization.Serializable
@Serializable data class ClientQuickAction(val id: String, val title: String, val prompt: String, val subtitle: String? = null, val icon: String? = null)
@Serializable data class ClientModelPreset(val id: String, val label: String, val model: String, val effort: String? = null, val subtitle: String? = null, val isDefault: Boolean = false)
@Serializable data class ClientProfile(val mode: String = "developer", val appTitle: String? = null, val defaultAgent: String? = null, val defaultModel: String? = null, val defaultPermissionMode: String? = null, val defaultDirectory: String? = null, val hideExecutionDetails: Boolean = false, val quickActions: List<ClientQuickAction> = emptyList(), val modelPresets: List<ClientModelPreset> = emptyList())
@Serializable data class HubSettingsResponse(val clientProfile: ClientProfile? = null)
