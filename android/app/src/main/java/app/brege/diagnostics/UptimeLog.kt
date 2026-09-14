package app.brege.diagnostics

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Local log of service lifecycle events, used to measure service survival per OEM.
 * Contains no message content; shared only when the user exports it.
 */
object UptimeLog {
    private const val MAX_BYTES = 512 * 1024
    private var file: File? = null
    private val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    fun init(context: Context) {
        file = File(context.filesDir, "uptime.log")
        record("process start (${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}, API ${android.os.Build.VERSION.SDK_INT})")
    }

    @Synchronized
    fun record(message: String) {
        val f = file ?: return
        if (f.length() > MAX_BYTES) {
            val tail = f.readText().takeLast(MAX_BYTES / 2)
            f.writeText(tail)
        }
        f.appendText("${format.format(Date())}  $message\n")
    }

    fun read(): String = file?.takeIf { it.exists() }?.readText().orEmpty()

    fun file(): File? = file
}
