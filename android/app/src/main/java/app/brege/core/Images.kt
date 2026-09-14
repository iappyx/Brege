package app.brege.core

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import java.io.ByteArrayOutputStream

/** Renders a drawable (app icon, avatar) as a square PNG for the Mac. */
fun Drawable.toPng(size: Int): ByteArray {
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    setBounds(0, 0, size, size)
    draw(Canvas(bitmap))
    return ByteArrayOutputStream().use {
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        it.toByteArray()
    }
}
