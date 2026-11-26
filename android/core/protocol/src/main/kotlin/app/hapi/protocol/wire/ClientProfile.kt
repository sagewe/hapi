package app.hapi.protocol.wire
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
@Serializable data class ClientQuickAction(val id: String, val title: String, val prompt: String, val subtitle: String? = null, val icon: String? = null)
@Serializable data class ClientModelPreset(val id: String, val label: String, val model: String, val effort: String? = null, val subtitle: String? = null, val isDefault: Boolean = false)
@Serializable data class ClientProfile(val mode: String = "developer", val appTitle: String? = null, val defaultAgent: String? = null, val defaultModel: String? = null, val defaultPermissionMode: String? = null, val defaultDirectory: String? = null, val hideExecutionDetails: Boolean = false, val quickActions: List<ClientQuickAction> = emptyList(), val modelPresets: List<ClientModelPreset> = emptyList())
@OptIn(ExperimentalSerializationApi::class)
@Serializable data class HubSettingsResponse(@JsonNames("client_profile") val clientProfile: ClientProfile? = null)
