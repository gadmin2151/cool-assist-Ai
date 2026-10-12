package cc.idomus.meetprotocol

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SettingsStore(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences("private_settings", Context.MODE_PRIVATE)
    private val alias = context.packageName + ".openai-key.v1"

    @Synchronized
    fun read(): AppSettings =
        AppSettings(
            summaryModel = preferences.getString("summary_model", AppSettings().summaryModel)!!,
            transcriptionModel =
                preferences.getString("transcription_model", AppSettings().transcriptionModel)!!,
            language = preferences.getString("language", "ru").orEmpty().ifBlank { "auto" },
            hasKey = preferences.contains("key_ciphertext"),
        )

    @Synchronized
    fun save(settings: AppSettings, newKey: String? = null) {
        validate(settings)
        val editor =
            preferences
                .edit()
                .putString("summary_model", settings.summaryModel.trim())
                .putString("transcription_model", settings.transcriptionModel.trim())
                .putString("language", settings.language.trim().ifBlank { "auto" })
        if (newKey != null) {
            val key = newKey.trim()
            validateKey(key)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
            cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
            val ciphertext = cipher.doFinal(key.toByteArray(Charsets.UTF_8))
            editor
                .putString("key_ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .putString("key_iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .remove("credential_blocked")
        }
        check(editor.commit()) { "Не удалось сохранить настройки" }
        if (newKey != null) OpenAIClient.credentialsUpdated()
    }

    @Synchronized
    fun readKey(): String {
        val encrypted = preferences.getString("key_ciphertext", null) ?: return ""
        try {
            val iv =
                Base64.decode(
                    preferences.getString("key_iv", null) ?: error("Missing nonce"),
                    Base64.NO_WRAP,
                )
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, encryptionKey(), GCMParameterSpec(128, iv))
            cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
            return String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) {
            throw IllegalStateException(
                "Сохранённый API-ключ недоступен. Введите его заново в настройках."
            )
        }
    }

    @Synchronized
    fun removeKey() {
        check(
            preferences
                .edit()
                .remove("key_ciphertext")
                .remove("key_iv")
                .remove("credential_blocked")
                .commit()
        ) {
            "Не удалось удалить API-ключ"
        }
        OpenAIClient.credentialsUpdated()
    }

    @Synchronized
    fun credentialBlocked(): Boolean = preferences.getBoolean("credential_blocked", false)

    @Synchronized
    fun blockCredential() {
        check(preferences.edit().putBoolean("credential_blocked", true).commit())
    }

    @Synchronized
    fun unblockCredential() {
        check(preferences.edit().remove("credential_blocked").commit())
    }

    private fun encryptionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            alias,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .setRandomizedEncryptionRequired(true)
                        .build()
                )
            }
            .generateKey()
    }

    companion object {
        fun validateModel(value: String) {
            require(value.trim().matches(Regex("[A-Za-z0-9][A-Za-z0-9._:/-]{0,149}"))) {
                "Введите корректный ID модели"
            }
        }

        fun validateKey(value: String) {
            require(value.length in 20..1_024 && value.all { it.code in 33..126 }) {
                "Введите полный API-ключ OpenAI без пробелов"
            }
        }

        fun validate(settings: AppSettings) {
            validateModel(settings.summaryModel)
            validateModel(settings.transcriptionModel)
            require(
                settings.language.isBlank() ||
                    settings.language == "auto" ||
                    settings.language.matches(Regex("[a-z]{2,3}"))
            ) {
                "Укажите код языка или auto"
            }
        }
    }
}
