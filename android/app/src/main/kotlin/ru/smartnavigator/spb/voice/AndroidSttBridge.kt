package ru.smartnavigator.spb.voice

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Thin bridge to the platform SpeechRecognizer. The Flutter client always
 * requests the ordinary system recognizer, which may resolve to an on-device
 * or network implementation of the device's speech service. Recognition is
 * started only after the app has recorded the user's consent.
 *
 * Audio is owned and processed by the Android speech service. This bridge
 * never records, buffers or persists audio and never logs recognized text.
 * Every callback is tagged with a session id so a cancelled or replaced
 * session cannot deliver a late transcript.
 */
class AndroidSttBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "smartnavigator/android_stt"
        const val EVENTS_CHANNEL = "smartnavigator/android_stt_events"

        private const val PERMISSION_REQUEST = 43122
        private const val SUPPORT_TIMEOUT_MS = 2500L
        private const val MAX_BIAS_STRINGS = 24
        private const val MAX_BIAS_CHARS = 1200

        private const val MODE_ON_DEVICE = "onDevice"
        private const val MODE_ONLINE = "online"

        private const val LANGUAGE = "ru-RU"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENTS_CHANNEL)

    private var events: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var sessionCounter = 0L
    private var activeSession = 0L
    private var mode = MODE_ON_DEVICE
    private var startedAt = 0L
    private var speechStartAt = 0L
    private var endOfSpeechAt = 0L
    private var firstPartialAt = 0L
    private var finalDelivered = false

    private var pendingStart: MethodChannel.Result? = null
    private var pendingStartMode = MODE_ON_DEVICE
    private var pendingStartBias: List<String> = emptyList()
    private var pendingPermission: MethodChannel.Result? = null
    private var released = false

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (released) {
            result.error("released", "Системное распознавание уже закрыто.", null)
            return
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { onMethodCall(call, result) }
            return
        }
        when (call.method) {
            "status" -> result.success(statusPayload())
            "checkSupport" -> handleCheckSupport(result)
            "requestPermission" -> handlePermissionRequest(result)
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "cancel" -> handleCancel(result)
            "openPermissionSettings" -> {
                openPermissionSettings()
                result.success(null)
            }
            "openLanguageSettings" -> {
                openLanguageSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun statusPayload(): Map<String, Any?> = mapOf(
        "supported" to SpeechRecognizer.isRecognitionAvailable(activity),
        "onDeviceSupported" to onDeviceAvailable(),
        "permission" to permissionState(),
        "engine" to "android-speech-recognizer",
        "maxDurationSeconds" to 30,
    )

    private fun onDeviceAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

    /**
     * API 33+ can report installed/pending Russian on-device languages.
     * API 31-32 has no such query; the UI must treat the result as unknown
     * and react to the actual launch error.
     */
    private fun handleCheckSupport(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.success(
                mapOf(
                    "supported" to false,
                    "onDeviceSupported" to false,
                    "ruStatus" to "unsupported",
                ),
            )
            return
        }
        if (!onDeviceAvailable()) {
            result.success(
                mapOf(
                    "supported" to true,
                    "onDeviceSupported" to false,
                    "ruStatus" to "unsupported",
                ),
            )
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(
                mapOf(
                    "supported" to true,
                    "onDeviceSupported" to true,
                    "ruStatus" to "unknown",
                ),
            )
            return
        }
        val recognizer = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } catch (_: Throwable) {
            result.success(
                mapOf(
                    "supported" to true,
                    "onDeviceSupported" to true,
                    "ruStatus" to "unknown",
                ),
            )
            return
        }
        var completed = false
        val finish: (Map<String, Any?>) -> Unit = { payload ->
            if (!completed) {
                completed = true
                try {
                    recognizer.destroy()
                } catch (_: Throwable) {
                    // Nothing to release.
                }
                result.success(payload)
            }
        }
        mainHandler.postDelayed(
            {
                finish(
                    mapOf(
                        "supported" to true,
                        "onDeviceSupported" to true,
                        "ruStatus" to "unknown",
                    ),
                )
            },
            SUPPORT_TIMEOUT_MS,
        )
        try {
            recognizer.checkRecognitionSupport(
                recognitionIntent(MODE_ON_DEVICE, emptyList()),
                ContextCompat.getMainExecutor(activity),
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        val installed = runCatching {
                            support.installedOnDeviceLanguages.any(::isRussian)
                        }.getOrDefault(false)
                        val pending = runCatching {
                            support.pendingOnDeviceLanguages.any(::isRussian)
                        }.getOrDefault(false)
                        val supported = runCatching {
                            support.supportedOnDeviceLanguages.any(::isRussian)
                        }.getOrDefault(false)
                        val ruStatus = when {
                            installed -> "installed"
                            pending -> "pending"
                            supported -> "downloadRequired"
                            else -> "unsupported"
                        }
                        finish(
                            mapOf(
                                "supported" to true,
                                "onDeviceSupported" to true,
                                "ruStatus" to ruStatus,
                            ),
                        )
                    }

                    override fun onError(error: Int) {
                        finish(
                            mapOf(
                                "supported" to true,
                                "onDeviceSupported" to true,
                                "ruStatus" to "unknown",
                            ),
                        )
                    }
                },
            )
        } catch (_: Throwable) {
            finish(
                mapOf(
                    "supported" to true,
                    "onDeviceSupported" to true,
                    "ruStatus" to "unknown",
                ),
            )
        }
    }

    private fun isRussian(language: String?): Boolean =
        language != null &&
            (language.equals(LANGUAGE, ignoreCase = true) ||
                language.startsWith("ru", ignoreCase = true))

    private fun handlePermissionRequest(result: MethodChannel.Result) {
        if (hasAudioPermission()) {
            result.success("granted")
            return
        }
        if (pendingPermission != null || pendingStart != null) {
            result.error("busy", "Запрос разрешения уже выполняется.", null)
            return
        }
        pendingPermission = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST,
        )
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val requestedMode = call.argument<String>("engine") ?: MODE_ON_DEVICE
        if (requestedMode != MODE_ON_DEVICE && requestedMode != MODE_ONLINE) {
            result.error("invalidEngine", "Неизвестный движок распознавания.", null)
            return
        }
        val bias = sanitizeBias(call.argument<List<*>>("bias"))
        if (recognizer != null) {
            result.error("busy", "Распознавание уже выполняется.", null)
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            result.error(
                "modelUnavailable",
                "На устройстве нет системного распознавания речи.",
                null,
            )
            return
        }
        if (requestedMode == MODE_ON_DEVICE && !onDeviceAvailable()) {
            result.error(
                "languageUnavailable",
                "Встроенное распознавание русского недоступно на этом устройстве.",
                null,
            )
            return
        }
        if (!hasAudioPermission()) {
            if (pendingStart != null || pendingPermission != null) {
                result.error("busy", "Запрос разрешения уже выполняется.", null)
                return
            }
            pendingStart = result
            pendingStartMode = requestedMode
            pendingStartBias = bias
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                PERMISSION_REQUEST,
            )
            return
        }
        beginListening(requestedMode, bias, result)
    }

    private fun sanitizeBias(raw: List<*>?): List<String> =
        raw
            ?.mapNotNull { (it as? String)?.trim() }
            ?.filter { it.isNotEmpty() }
            ?.map { it.take(120) }
            ?.take(MAX_BIAS_STRINGS)
            ?.let { values ->
                var total = 0
                values.takeWhile { value ->
                    total += value.length
                    total <= MAX_BIAS_CHARS
                }
            }
            ?: emptyList()

    private fun beginListening(
        requestedMode: String,
        bias: List<String>,
        result: MethodChannel.Result,
    ) {
        val created = try {
            if (requestedMode == MODE_ON_DEVICE) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            } else {
                SpeechRecognizer.createSpeechRecognizer(activity)
            }
        } catch (_: Throwable) {
            result.error(
                "microphoneUnavailable",
                "Не удалось запустить системное распознавание.",
                null,
            )
            return
        }
        mode = requestedMode
        sessionCounter += 1
        val sessionId = sessionCounter
        activeSession = sessionId
        startedAt = SystemClock.elapsedRealtime()
        speechStartAt = 0L
        endOfSpeechAt = 0L
        firstPartialAt = 0L
        finalDelivered = false
        recognizer = created
        created.setRecognitionListener(listener(sessionId))
        try {
            created.startListening(recognitionIntent(requestedMode, bias))
        } catch (_: Throwable) {
            recognizer = null
            try {
                created.destroy()
            } catch (_: Throwable) {
                // Nothing to release.
            }
            result.error(
                "microphoneUnavailable",
                "Не удалось включить микрофон.",
                null,
            )
            return
        }
        result.success(
            mapOf(
                "session" to sessionId,
                "engine" to engineName(requestedMode),
            ),
        )
    }

    private fun recognitionIntent(
        requestedMode: String,
        bias: List<String>,
    ): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(
            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
        )
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, LANGUAGE)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, LANGUAGE)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
        if (requestedMode == MODE_ON_DEVICE) {
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        if (bias.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                putExtra(
                    RecognizerIntent.EXTRA_BIASING_STRINGS,
                    ArrayList(bias),
                )
            }
        }
    }

    private fun engineName(requestedMode: String): String =
        if (requestedMode == MODE_ON_DEVICE) {
            "android-on-device"
        } else {
            "android-system"
        }

    private fun listener(sessionId: Long) = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            emit(sessionId, "ready")
        }

        override fun onBeginningOfSpeech() {
            if (sessionId != activeSession) return
            speechStartAt = SystemClock.elapsedRealtime()
        }

        override fun onRmsChanged(rmsdB: Float) = Unit

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() {
            if (sessionId != activeSession || endOfSpeechAt != 0L) return
            endOfSpeechAt = SystemClock.elapsedRealtime()
            emit(sessionId, "endOfSpeech")
        }

        override fun onError(error: Int) {
            if (sessionId != activeSession) return
            val mapped = mapError(error)
            // The recognizer already ended the session; only destroy it so
            // cancel() cannot trigger a second callback after the error.
            finishRecognizer()
            emitError(sessionId, mapped.first, mapped.second)
        }

        override fun onResults(results: Bundle?) {
            if (sessionId != activeSession) return
            val text = bestText(results)
            finalDelivered = true
            finishRecognizer()
            if (text.isEmpty()) {
                emitError(
                    sessionId,
                    "emptySpeech",
                    "Не удалось расслышать речь.",
                )
                return
            }
            emit(
                sessionId,
                "final",
                text = text,
                extra = mapOf(
                    "engine" to engineName(mode),
                    "timings" to timings(),
                ),
            )
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (sessionId != activeSession) return
            val text = bestText(partialResults)
            if (text.isEmpty()) return
            if (firstPartialAt == 0L) {
                firstPartialAt = SystemClock.elapsedRealtime()
            }
            emit(sessionId, "partial", text = text)
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun bestText(bundle: Bundle?): String {
        val values = bundle
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?: return ""
        return values.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
    }

    private fun timings(): Map<String, Int> {
        val now = SystemClock.elapsedRealtime()
        fun elapsed(start: Long): Int =
            if (start <= 0L) 0 else (now - start).toInt().coerceAtLeast(0)
        val finalMs = elapsed(startedAt)
        val speechMs = if (speechStartAt > 0L && endOfSpeechAt > speechStartAt) {
            (endOfSpeechAt - speechStartAt).toInt()
        } else {
            finalMs
        }
        return mapOf(
            "firstPartialMs" to elapsed(firstPartialAt),
            "endOfSpeechMs" to elapsed(endOfSpeechAt),
            "finalMs" to finalMs,
            "speechMs" to speechMs,
            "totalMs" to finalMs,
        )
    }

    private fun emit(
        sessionId: Long,
        type: String,
        text: String? = null,
        extra: Map<String, Any?> = emptyMap(),
    ) {
        val sink = events ?: return
        val payload = HashMap<String, Any?>()
        payload["session"] = sessionId
        payload["type"] = type
        if (text != null) payload["text"] = text
        payload.putAll(extra)
        mainHandler.post {
            if (sessionId == activeSession || type == "final" || type == "error") {
                sink.success(payload)
            }
        }
    }

    private fun emitError(sessionId: Long, code: String, message: String) {
        emit(
            sessionId,
            "error",
            extra = mapOf("code" to code, "message" to message),
        )
    }

    private fun mapError(error: Int): Pair<String, String> = when (error) {
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "timeout" to
            "Системное распознавание не ответило вовремя."
        SpeechRecognizer.ERROR_NETWORK -> "network" to
            "Нет связи с системной службой распознавания."
        SpeechRecognizer.ERROR_AUDIO -> "microphoneUnavailable" to
            "Не удалось получить звук с микрофона."
        SpeechRecognizer.ERROR_SERVER -> "recognitionFailed" to
            "Системная служба распознавания вернула ошибку."
        SpeechRecognizer.ERROR_CLIENT -> "recognitionFailed" to
            "Системное распознавание было прервано."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
        SpeechRecognizer.ERROR_NO_MATCH,
        -> "emptySpeech" to "Не удалось расслышать речь."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS,
        -> "busy" to "Распознавание уже занято. Попробуйте ещё раз."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permissionDenied" to
            "Микрофон недоступен."
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "network" to
            "Системная служба распознавания отключилась."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "languageUnavailable" to
            "Системное распознавание не поддерживает русский язык."
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "modelUnavailable" to
            "Русский языковой пакет не установлен. Откройте настройки " +
                "распознавания и загрузите его."
        SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT -> "recognitionFailed" to
            "Не удалось проверить поддержку русского языка."
        else -> "recognitionFailed" to
            "Не удалось распознать речь системной службой."
    }

    private fun handleStop(result: MethodChannel.Result) {
        val current = recognizer
        if (current == null) {
            // The final result may already have arrived by itself.
            result.success(finalDelivered)
            return
        }
        try {
            current.stopListening()
        } catch (_: Throwable) {
            // A completed or cancelled session has nothing left to stop.
        }
        result.success(true)
    }

    private fun handleCancel(result: MethodChannel.Result) {
        activeSession = 0L
        finalDelivered = false
        pendingStart = null
        pendingStartMode = MODE_ON_DEVICE
        pendingStartBias = emptyList()
        val permission = pendingPermission
        pendingPermission = null
        permission?.error("cancelled", "Голосовой ввод отменён.", null)
        releaseRecognizer()
        result.success(null)
    }

    private fun releaseRecognizer() = destroyRecognizer(cancelFirst = true)

    private fun finishRecognizer() = destroyRecognizer(cancelFirst = false)

    private fun destroyRecognizer(cancelFirst: Boolean) {
        val current = recognizer
        recognizer = null
        if (current != null) {
            if (cancelFirst) {
                try {
                    current.cancel()
                } catch (_: Throwable) {
                    // Already finished.
                }
            }
            try {
                current.destroy()
            } catch (_: Throwable) {
                // Already released.
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val permission = pendingPermission
        pendingPermission = null
        val permanentlyDenied = !granted &&
            !ActivityCompat.shouldShowRequestPermissionRationale(
                activity,
                Manifest.permission.RECORD_AUDIO,
            )
        if (permission != null) {
            permission.success(
                when {
                    granted -> "granted"
                    permanentlyDenied -> "permanentlyDenied"
                    else -> "denied"
                },
            )
            return
        }
        val start = pendingStart ?: return
        val requestedMode = pendingStartMode
        val bias = pendingStartBias
        pendingStart = null
        pendingStartMode = MODE_ON_DEVICE
        pendingStartBias = emptyList()
        if (granted) {
            beginListening(requestedMode, bias, start)
        } else {
            start.error(
                if (permanentlyDenied) {
                    "permissionPermanentlyDenied"
                } else {
                    "permissionDenied"
                },
                "Микрофон недоступен. Разрешите доступ в настройках.",
                null,
            )
        }
    }

    private fun hasAudioPermission(): Boolean = ContextCompat.checkSelfPermission(
        activity,
        Manifest.permission.RECORD_AUDIO,
    ) == PackageManager.PERMISSION_GRANTED

    private fun permissionState(): String =
        if (hasAudioPermission()) "granted" else "denied"

    private fun openPermissionSettings() {
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.parse("package:${activity.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {
            // Manual search remains available.
        }
    }

    private fun openLanguageSettings() {
        try {
            activity.startActivity(
                Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Throwable) {
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: Throwable) {
                // Manual search remains available.
            }
        }
    }

    fun release() {
        if (released) return
        released = true
        try {
            methodChannel.setMethodCallHandler(null)
        } catch (_: Throwable) {
            // The engine may already be detached.
        }
        try {
            eventChannel.setStreamHandler(null)
        } catch (_: Throwable) {
            // The engine may already be detached.
        }
        events = null
        activeSession = 0L
        pendingStart = null
        pendingPermission = null
        releaseRecognizer()
    }
}
