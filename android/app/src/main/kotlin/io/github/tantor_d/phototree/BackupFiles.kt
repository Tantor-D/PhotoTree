package io.github.tantor_d.phototree

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Narrow read-only original identity and user-chosen document output adapter. */
class BackupFiles(private val activity: Activity, private val pickerGate: DocumentPickerGate) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null
    @Volatile private var inputEpoch = 0
    @Volatile private var hashEpoch = 0
    @Volatile private var inputStream: java.io.InputStream? = null
    private var inputSignal: CancellationSignal? = null
    private var openResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var saveBytes: ByteArray? = null
    companion object { const val LOCATION = 7041; const val SAVE = 7042; const val OPEN = 7043 }
    private fun permitted() = activity.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "originalPermission" -> result.success(permitted())
            "requestOriginalPermission" -> {
                if (permitted()) result.success(true)
                else if (permissionResult != null) result.error("busy", "Permission request active", null)
                else {
                    permissionResult = result
                    activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION), LOCATION)
                }
            }
            "cancelRead" -> { cancelRead(); result.success(null) }
            "fingerprint" -> {
              val epoch = hashEpoch
              worker.execute {
                try {
                    val answer = fingerprint(call, epoch)
                    main.post { result.success(answer) }
                } catch (_: Exception) {
                    main.post { result.error("unavailable", "Exact original is unavailable or changed", null) }
                }
            }
            }
            "filename" -> worker.execute {
                try { val name = checkedDescription(call)["filename"]; main.post { result.success(name) } }
                catch (_: Exception) { main.post { result.error("unavailable", "Media identity changed or inaccessible", null) } }
            }
            "size" -> worker.execute {
                try { val size = checkedSize(call); main.post { result.success(size) } }
                catch (_: Exception) { main.post { result.error("unavailable", "Media identity changed or inaccessible", null) } }
            }
            "open" -> {
                if (openResult != null || saveResult != null) { result.error("busy", "File operation active", null); return }
                if (!pickerGate.acquire(this)) { result.error("busy", "Directory picker active", null); return }
                openResult = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }, OPEN)
                } catch (_: Exception) { finishOpen(null, "Unable to open document dialog") }
            }
            "save" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (saveResult != null || openResult != null) { result.error("busy", "Save active", null); return }
                if (bytes == null || bytes.isEmpty() || bytes.size > 32 * 1024 * 1024) {
                    result.error("size", "Invalid backup size", null); return
                }
                if (!pickerGate.acquire(this)) { result.error("busy", "Directory picker active", null); return }
                saveResult = result; saveBytes = bytes
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, "PhotoTree-backup.json")
                    }, SAVE)
                } catch (_: Exception) { finishSave(false, "Unable to open save dialog") }
            }
            else -> result.notImplemented()
        }
    }
    fun permissionResult(request: Int): Boolean {
        if (request != LOCATION) return false
        permissionResult?.success(permitted()); permissionResult = null
        return true
    }
    fun activityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == OPEN) {
            if (code == Activity.RESULT_CANCELED) { finishOpen(null); return true }
            val uri = data?.data
            if (code != Activity.RESULT_OK || uri == null) { finishOpen(null, "Missing input document"); return true }
            val epoch = inputEpoch
            val signal = CancellationSignal()
            inputSignal = signal
            Thread {
                try {
                    val descriptor = activity.contentResolver.openFileDescriptor(uri, "r", signal) ?: throw IOException("No input descriptor")
                    val stream = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
                    val bytes = stream.use { input ->
                        synchronized(this) {
                            if (epoch != inputEpoch) throw IOException("Input cancelled")
                            inputStream = input
                        }
                        val output = ByteArrayOutputStream()
                        val chunk = ByteArray(64 * 1024)
                        while (true) {
                            if (epoch != inputEpoch) throw IOException("Input cancelled")
                            val count = input.read(chunk)
                            if (count < 0) break
                            if (output.size().toLong() + count > 32L * 1024 * 1024) throw InputTooLarge()
                            output.write(chunk, 0, count)
                        }
                        output.toByteArray()
                    }
                    main.post { finishOpen(bytes, epoch = epoch) }
                } catch (_: InputTooLarge) {
                    main.post { finishOpen(null, "Backup exceeds 32 MiB", epoch, "input_too_large") }
                } catch (_: Exception) {
                    main.post { finishOpen(null, "Input could not be read", epoch) }
                }
            }.start()
            return true
        }
        if (request != SAVE) return false
        if (code == Activity.RESULT_CANCELED) { finishSave(false); return true }
        val uri = data?.data
        val bytes = saveBytes
        if (code != Activity.RESULT_OK || uri == null || bytes == null) {
            finishSave(false, "Missing output document"); return true
        }
        worker.execute {
            try {
                val resolver = activity.contentResolver
                // A null stream, write, flush, close or readback failure is never success.
                (resolver.openOutputStream(uri, "wt") ?: throw IOException("No output stream")).use { out ->
                    out.write(bytes); out.flush()
                }
                (resolver.openInputStream(uri) ?: throw IOException("No verification stream")).use { input ->
                    val chunk = ByteArray(64 * 1024)
                    var offset = 0
                    while (true) {
                        val count = input.read(chunk)
                        if (count < 0) break
                        if (offset + count > bytes.size) throw IOException("Extra output bytes")
                        for (i in 0 until count) if (chunk[i] != bytes[offset + i]) throw IOException("Output differs")
                        offset += count
                    }
                    if (offset != bytes.size) throw IOException("Incomplete output")
                }
                main.post { finishSave(true) }
            } catch (_: Exception) {
                main.post { finishSave(false, "Output could not be completed and verified") }
            }
        }
        return true
    }
    private fun cancelRead() {
        val stream = synchronized(this) {
            inputEpoch++; hashEpoch++
            val active = inputStream; inputStream = null
            active
        }
        inputSignal?.cancel(); inputSignal = null
        try { stream?.close() } catch (_: Exception) { }
        val result = openResult; openResult = null
        if (result != null) pickerGate.release(this)
        result?.success(null)
    }
    private class InputTooLarge : IOException()
    private fun finishOpen(bytes: ByteArray?, error: String? = null, epoch: Int = inputEpoch, errorCode: String = "input_read") {
        if (epoch != inputEpoch) return
        inputStream = null; inputSignal = null
        val result = openResult; openResult = null
        if (result != null) pickerGate.release(this)
        if (error != null) result?.error(errorCode, error, null) else result?.success(bytes)
    }
    private fun checkedSize(call: MethodCall): Long = checkedDescription(call)["size"] as Long
    private fun checkedDescription(call: MethodCall): Map<String, Any?> {
        val volume = call.argument<String>("volume")
        val id = call.argument<Number>("id")?.toLong() ?: 0
        if (volume != MediaStore.VOLUME_EXTERNAL_PRIMARY || id <= 0) throw IOException("Invalid identity")
        val expectedVersion = call.argument<String>("version") ?: throw IOException("No version")
        val mediaKind = MediaKind.from(call.argument<Any>("mediaKind"))
        mediaKind.requireRead(activity)
        val uri = mediaKind.uri(id)
        if (MediaStore.getVersion(activity, volume) != expectedVersion) throw IOException("Version changed")
        val answer = activity.contentResolver.query(uri, arrayOf("date_added","datetaken","width","height","relative_path","_size","_display_name"), null,null,null)?.use { c ->
            if (!c.moveToFirst()) throw IOException("Missing photo")
            for ((index, key) in listOf("addedSeconds","takenMs","width","height").withIndex()) {
                if (c.getLong(index) != call.argument<Number>(key)?.toLong()) throw IOException("Identity changed")
            }
            if (c.getString(4) != call.argument<String>("directory") || c.isNull(5) || c.getLong(5) < 0) throw IOException("Metadata unavailable")
            mapOf("size" to c.getLong(5), "filename" to c.getString(6))
        } ?: throw IOException("No cursor")
        if (MediaStore.getVersion(activity, volume) != expectedVersion) throw IOException("Version changed")
        return answer
    }
    private fun finishSave(complete: Boolean, error: String? = null) {
        val result = saveResult; saveResult = null; saveBytes = null
        pickerGate.release(this)
        if (error != null) result?.error("output", error, null) else result?.success(complete)
    }
    private fun fingerprint(call: MethodCall, epoch: Int): Map<String, Any> {
        if (!permitted()) throw SecurityException("Original permission missing")
        val volume = call.argument<String>("volume")
        val id = call.argument<Number>("id")?.toLong() ?: 0
        if (volume != MediaStore.VOLUME_EXTERNAL_PRIMARY || id <= 0) throw IOException("Invalid identity")
        val expectedVersion = call.argument<String>("version") ?: throw IOException("No version")
        val resolver = activity.contentResolver
        val mediaKind = MediaKind.from(call.argument<Any>("mediaKind"))
        mediaKind.requireRead(activity)
        val uri = mediaKind.uri(id)
        fun version() = MediaStore.getVersion(activity, volume)
        fun row(): List<String> = resolver.query(uri, arrayOf("date_added", "datetaken", "width", "height", "relative_path", "_display_name", "_size", "date_modified", "generation_modified"), null, null, null)?.use { c ->
            if (!c.moveToFirst()) throw IOException("Missing media")
            // Match MediaMetadata/Photo exactly: nullable numeric metadata is 0.
            // Descriptive text and freshness fields retain their source values.
            (0 until c.columnCount).map { index ->
                if (index < 4) c.getLong(index).toString() else c.getString(index) ?: ""
            }
        } ?: throw IOException("No media cursor")
        val before = row()
        if (version() != expectedVersion ||
            before.take(4) != listOf("addedSeconds", "takenMs", "width", "height").map { call.argument<Number>(it)?.toLong().toString() } ||
            before[4] != call.argument<String>("directory")) throw IOException("Identity changed")
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        (resolver.openInputStream(MediaStore.setRequireOriginal(uri)) ?: throw IOException("No original stream")).use { input ->
            val chunk = ByteArray(64 * 1024)
            while (true) {
                if (epoch != hashEpoch) throw IOException("Fingerprint cancelled")
                val count = input.read(chunk)
                if (count < 0) break
                digest.update(chunk, 0, count); size += count
            }
        }
        if (!permitted() || version() != expectedVersion || row() != before || size <= 0 || size != before[6].toLong()) throw IOException("Media changed")
        return mapOf("size" to size, "sha256" to digest.digest().joinToString("") { "%02x".format(it) }, "filename" to before[5])
    }
    fun close() { pickerGate.release(this); cancelRead(); worker.shutdownNow(); permissionResult = null; saveResult = null; saveBytes = null; openResult = null }
}
