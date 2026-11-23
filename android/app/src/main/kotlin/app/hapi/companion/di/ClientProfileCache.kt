package app.hapi.companion.di
import android.content.Context
import androidx.datastore.preferences.core.*
import androidx.datastore.preferences.preferencesDataStore
import app.hapi.protocol.wire.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
private val Context.clientProfiles by preferencesDataStore("client_profiles")
class ClientProfileCache(context: Context, hub: String) {
    private val store = context.applicationContext.clientProfiles
    private val key = stringPreferencesKey(hub)
    fun read(): ClientProfile? = runBlocking(Dispatchers.IO) {
        runCatching { store.data.first()[key]?.let { HapiJson.decodeFromString<ClientProfile>(it) } }.getOrNull()
    }
    suspend fun write(profile: ClientProfile?) {
        store.edit { if (profile == null) it.remove(key) else it[key] = HapiJson.encodeToString(profile) }
    }
}
val LocalClientProfile = androidx.compose.runtime.staticCompositionLocalOf<ClientProfile?> { null }
