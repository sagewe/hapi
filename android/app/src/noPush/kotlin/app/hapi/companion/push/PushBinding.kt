package app.hapi.companion.push
import android.content.Context
/** This build contains no push SDK or registration token. */
object PushBinding {
    fun isAvailable(context: Context): Boolean = false
    suspend fun currentToken(context: Context): String? = null
}
