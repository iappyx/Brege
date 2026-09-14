package app.brege.messages

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.ContactsContract.PhoneLookup
import java.io.ByteArrayOutputStream
import uniffi.brege_ffi.ContactPhotoData

/** Contact thumbnails for the Mac's Messages window. */
object ContactPhotos {
    private const val MAX_BYTES = 64 * 1024
    private const val SIZE = 160

    /** One entry per address; an empty photo means there is none (or no contacts permission). */
    fun lookup(context: Context, addresses: List<String>): List<ContactPhotoData> {
        val allowed = context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
        return addresses.map { ContactPhotoData(it, if (allowed) photo(context, it) else ByteArray(0)) }
    }

    private fun photo(context: Context, address: String): ByteArray = runCatching {
        val lookup = Uri.withAppendedPath(PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address))
        val thumbnail = context.contentResolver.query(lookup, arrayOf(PhoneLookup.PHOTO_THUMBNAIL_URI), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: return ByteArray(0)
        val bytes = context.contentResolver.openInputStream(Uri.parse(thumbnail))?.use { it.readBytes() }
            ?: return ByteArray(0)
        if (bytes.size <= MAX_BYTES) bytes else shrink(bytes)
    }.getOrDefault(ByteArray(0))

    private fun shrink(bytes: ByteArray): ByteArray {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return ByteArray(0)
        val scaled = Bitmap.createScaledBitmap(bitmap, SIZE, SIZE * bitmap.height / maxOf(bitmap.width, 1), true)
        return ByteArrayOutputStream().use {
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, it)
            it.toByteArray()
        }.takeIf { it.size <= MAX_BYTES } ?: ByteArray(0)
    }
}
