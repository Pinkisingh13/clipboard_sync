package com.example.android_app

import android.content.Context
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

data class PairedDevice(
    val fingerprint: String,
    val name: String
)

class PairingStore(context: Context) {
    private val preferences = context.getSharedPreferences("clipboard_sync_pairing", Context.MODE_PRIVATE)
    private val keyAlias = "clipboard_sync_pairing_key"

    fun deviceId(): String {
        return preferences.getString("device_id", null) ?: java.util.UUID.randomUUID().toString()
            .also { preferences.edit().putString("device_id", it).apply() }
    }

    fun secret(fingerprint: String): String? {
        return preferences.getString("secret_${normalizeFingerprint(fingerprint)}", null)?.let(::decrypt)
    }

    fun saveSecret(fingerprint: String, secret: String) {
        preferences.edit()
            .putString("secret_${normalizeFingerprint(fingerprint)}", encrypt(secret))
            .apply()
    }

    fun forget(fingerprint: String) {
        val normalized = normalizeFingerprint(fingerprint)
        preferences.edit()
            .remove("secret_$normalized")
            .remove("name_$normalized")
            .apply()
    }

    fun saveDeviceName(fingerprint: String, name: String) {
        preferences.edit()
            .putString("name_${normalizeFingerprint(fingerprint)}", name)
            .apply()
    }

    fun pairedDevices(): List<PairedDevice> =
        preferences.all.keys
            .filter { it.startsWith("secret_") }
            .mapNotNull { key ->
                val fingerprint = key.removePrefix("secret_")
                if (secret(fingerprint) == null) {
                    null
                } else {
                    PairedDevice(
                        fingerprint = fingerprint,
                        name = preferences.getString("name_$fingerprint", null)
                            ?: "Saved Mac",
                    )
                }
            }

    private fun normalizeFingerprint(fingerprint: String): String =
        fingerprint.replace(":", "").replace(Regex("\\s"), "").uppercase()

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
        }.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipher.doFinal(value.toByteArray()), Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String? = try {
        val parts = value.split(":", limit = 2)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP))
        )
        String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)))
    } catch (_: Exception) {
        null
    }
}
