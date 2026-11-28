package app.hapi.protocol.wire
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames

@Serializable
data class ClientQuickAction(
    val id: String,
    val title: String,
    val prompt: String,
    val subtitle: String? = null,
    val icon: String? = null,
    val opensAttachment: Boolean? = null,
    val isCustom: Boolean? = null,
    val hidden: Boolean? = null,
    val skillSlug: String? = null,
    val referenceDocIds: List<String>? = null,
    val summaryPoints: List<String>? = null,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ClientModelPreset(
    val id: String,
    val label: String,
    val model: String,
    val effort: String? = null,
    val subtitle: String? = null,
    @JsonNames("is_default") val isDefault: Boolean = false,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ClientProfile(
    val mode: String = "developer",
    @JsonNames("app_title") val appTitle: String? = null,
    @JsonNames("default_agent") val defaultAgent: String? = null,
    @JsonNames("default_model") val defaultModel: String? = null,
    @JsonNames("default_permission_mode") val defaultPermissionMode: String? = null,
    @JsonNames("default_directory") val defaultDirectory: String? = null,
    @JsonNames("hide_execution_details") val hideExecutionDetails: Boolean = false,
    @JsonNames("quick_actions") val quickActions: List<ClientQuickAction> = emptyList(),
    @JsonNames("model_presets") val modelPresets: List<ClientModelPreset> = emptyList(),
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class HubSettingsResponse(@JsonNames("client_profile") val clientProfile: ClientProfile? = null)
