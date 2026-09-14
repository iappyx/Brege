package app.brege.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores the identity seed and database key encrypted with an AES-256-GCM key held in
 * Android Keystore. Works from API 29; EncryptedSharedPreferences is deprecated.
 */
class SecretStore(context: Context) {
    private val dir = File(context.noBackupFilesDir, "secrets").apply { mkdirs() }

    fun loadOrCreate(name: String, create: () -> ByteArray): ByteArray {
        val file = File(dir, "$name.bin")
        if (file.exists()) {
            return decrypt(file.readBytes())
        }
        val value = create()
        val tmp = File(dir, "$name.tmp")
        tmp.writeBytes(encrypt(value))
        check(tmp.renameTo(file)) { "could not persist $name" }
        return value
    }

    private fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(plain)
    }

    private fun decrypt(blob: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_LENGTH))
        return cipher.doFinal(blob, IV_LENGTH, blob.size - IV_LENGTH)
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return try {
            generate(strongBox = true)
        } catch (_: StrongBoxUnavailableException) {
            generate(strongBox = false)
        }
    }

    private fun generate(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // No user authentication: the service must reconnect while the phone is locked.
            .setUserAuthenticationRequired(false)
            .setIsStrongBoxBacked(strongBox)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "brege-secrets-v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
    }
}
