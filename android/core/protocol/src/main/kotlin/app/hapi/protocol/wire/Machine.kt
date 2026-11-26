package app.hapi.protocol.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject

/**
 * Machine (runner host) row. Decodes both Reins Native v1 (`id`, `namespace`,
 * `name`, `platform`, `capabilities`, `active`, `last_seen_at`) and legacy HAPI
 * `MachineSchema` JSON.
 */
@Serializable(with = MachineSerializer::class)
data class Machine(
    val id: String,
    val namespace: String,
    val seq: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val active: Boolean,
    val activeAt: Long,
    val metadata: MachineMetadata? = null,
    val metadataVersion: Long,
    val runnerState: RunnerState? = null,
    val runnerStateVersion: Long,
    val health: MachineHealth? = null,
)

@Serializable
private data class LegacyMachineSurrogate(
    val id: String,
    val namespace: String,
    val seq: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val active: Boolean,
    val activeAt: Long,
    val metadata: MachineMetadata? = null,
    val metadataVersion: Long,
    val runnerState: RunnerState? = null,
    val runnerStateVersion: Long,
    val health: MachineHealth? = null,
) {
    fun toMachine() = Machine(
        id = id,
        namespace = namespace,
        seq = seq,
        createdAt = createdAt,
        updatedAt = updatedAt,
        active = active,
        activeAt = activeAt,
        metadata = metadata,
        metadataVersion = metadataVersion,
        runnerState = runnerState,
        runnerStateVersion = runnerStateVersion,
        health = health,
    )
}

internal object MachineSerializer : KSerializer<Machine> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("app.hapi.protocol.wire.Machine", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): Machine {
        val input = decoder as? JsonDecoder
            ?: throw SerializationException("Machine supports JSON only")
        val obj = input.decodeJsonElement() as? JsonObject
            ?: throw SerializationException("Machine must be a JSON object")
        if (obj.containsKey("last_seen_at") || !obj.containsKey("seq")) {
            return decodeV1Machine(obj)
        }
        return HapiJson.decodeFromJsonElement(LegacyMachineSurrogate.serializer(), obj).toMachine()
    }

    override fun serialize(encoder: Encoder, value: Machine) {
        val output = encoder as? JsonEncoder
            ?: throw SerializationException("Machine supports JSON only")
        val surrogate = LegacyMachineSurrogate(
            id = value.id,
            namespace = value.namespace,
            seq = value.seq,
            createdAt = value.createdAt,
            updatedAt = value.updatedAt,
            active = value.active,
            activeAt = value.activeAt,
            metadata = value.metadata,
            metadataVersion = value.metadataVersion,
            runnerState = value.runnerState,
            runnerStateVersion = value.runnerStateVersion,
            health = value.health,
        )
        output.encodeJsonElement(HapiJson.encodeToJsonElement(LegacyMachineSurrogate.serializer(), surrogate))
    }

    private fun decodeV1Machine(obj: JsonObject): Machine {
        val id = obj["id"].stringOrNull
            ?: throw SerializationException("Machine.id must be a string")
        val namespace = obj["namespace"].stringOrNull ?: "default"
        val lastSeenAt = obj["last_seen_at"].longOrNull ?: obj["updatedAt"].longOrNull ?: 0L
        val active = obj["active"].boolOrNull ?: false
        val name = obj["name"].stringOrNull ?: id
        val platform = obj["platform"].stringOrNull ?: ""
        val rawCaps = obj["capabilities"]
        val capStrings: List<String>? = when (rawCaps) {
            is JsonArray -> rawCaps.mapNotNull { it.stringOrNull }
            is JsonObject -> rawCaps.entries.mapNotNull { (k, v) -> if (v.boolOrNull == true) k else null }
            else -> null
        }
        val metadata = (obj["metadata"] as? JsonObject)?.let {
            runCatching { HapiJson.decodeFromJsonElement(MachineMetadata.serializer(), it) }.getOrNull()
        } ?: MachineMetadata(
            host = name,
            platform = platform,
            happyCliVersion = "reins-v1",
            capabilities = capStrings,
        )
        val runnerState = (obj["runnerState"] as? JsonObject)?.let {
            runCatching { HapiJson.decodeFromJsonElement(RunnerState.serializer(), it) }.getOrNull()
        } ?: RunnerState(
            status = if (active) "running" else "stopped",
            capabilities = rawCaps,
        )
        return Machine(
            id = id,
            namespace = namespace,
            seq = obj["seq"].longOrNull ?: 1L,
            createdAt = obj["createdAt"].longOrNull ?: lastSeenAt,
            updatedAt = obj["updatedAt"].longOrNull ?: lastSeenAt,
            active = active,
            activeAt = obj["activeAt"].longOrNull ?: lastSeenAt,
            metadata = metadata,
            metadataVersion = obj["metadataVersion"].longOrNull ?: 1L,
            runnerState = runnerState,
            runnerStateVersion = obj["runnerStateVersion"].longOrNull ?: 1L,
            health = (obj["health"] as? JsonObject)?.let {
                runCatching { HapiJson.decodeFromJsonElement(MachineHealth.serializer(), it) }.getOrNull()
            },
        )
    }
}

/** `MachineMetadataSchema`. */
@Serializable
data class MachineMetadata(
    val host: String,
    val platform: String,
    val happyCliVersion: String,
    val displayName: String? = null,
    val homeDir: String? = null,
    val happyHomeDir: String? = null,
    val happyLibDir: String? = null,
    val workspaceRoots: List<String>? = null,
    /** Machine-scoped RPC capability ids this runner registers. */
    val capabilities: List<String>? = null,
    @Serializable(with = LenientEpochMs::class)
    val startedCliMtimeMs: Long? = null,
    @Serializable(with = LenientEpochMs::class)
    val installedCliMtimeMs: Long? = null,
    val supervisedRestart: Boolean? = null,
)

/**
 * `RunnerStateSchema` — cheaply-typed scalars only; `capabilities` (agent
 * config descriptors) and `lastSpawnError` stay raw until a feature needs them.
 */
@Serializable
data class RunnerState(
    /** `'running' | 'shutting-down'` or any future string (zod union with string). */
    val status: String,
    val pid: Int? = null,
    val httpPort: Int? = null,
    val startedAt: Long? = null,
    val capabilities: JsonElement? = null,
    val shutdownRequestedAt: Long? = null,
    val shutdownSource: String? = null,
    val lastSpawnError: JsonElement? = null,
)

/** `MachineHealthSchema`. */
@Serializable
data class MachineHealth(
    val collectedAt: Long,
    val cpuCount: Int? = null,
    val load1m: Double? = null,
    val cpuPercent: Double? = null,
    val memoryPercent: Double? = null,
    val uptimeSeconds: Double? = null,
)

/**
 * Flat patch variant of the `machine-updated` SSE payload
 * (`MachinePatchSchema` — strict in zod).
 */
@Serializable
data class MachinePatch(
    val active: Boolean? = null,
    val activeAt: Long? = null,
    val updatedAt: Long? = null,
)

object MachinePatches {
    private val KNOWN_KEYS = setOf("active", "activeAt", "updatedAt")

    /**
     * Strict + non-empty parse mirroring the web's `getMachinePatch`
     * (`MachinePatchSchema.safeParse` + key-count check): any unknown key or
     * mistyped value → `null` (caller falls back to refetching machines), and
     * an empty `{}` is also `null`. Strictness is what separates a patch from
     * a full [Machine] payload.
     */
    fun parse(element: JsonElement?): MachinePatch? {
        val obj = element as? JsonObject ?: return null
        if (obj.isEmpty() || obj.keys.any { it !in KNOWN_KEYS }) return null
        val active = obj["active"]?.let { it.boolOrNull ?: return null }
        val activeAt = obj["activeAt"]?.let { it.longOrNull ?: return null }
        val updatedAt = obj["updatedAt"]?.let { it.longOrNull ?: return null }
        return MachinePatch(active = active, activeAt = activeAt, updatedAt = updatedAt)
    }
}
