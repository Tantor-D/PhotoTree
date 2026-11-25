package io.github.tantor_d.phototree

import android.app.Activity
import android.content.ContentUris
import android.os.CancellationSignal
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Single system confirmation, with identity and state read back on both sides. */
class SystemFavorites(private val activity: Activity, private val gate: DocumentPickerGate) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: Request? = null
    private var closed = false
    private var workerUnavailable = false
    private var readDeadline: Runnable? = null
    private var readSignal: CancellationSignal? = null
    private var launched = false
    private var resumed = false
    private var leftForConfirmation = false
    private var recovery: Runnable? = null
    private data class Request(val id: Long, val mediaKind: MediaKind, val version: String, val added: Long,
        val taken: Long, val width: Int, val height: Int, val value: Boolean,
        var result: MethodChannel.Result?, val requestCode: Int) {
        val uri get() = mediaKind.uri(id)
    }
    private class Stale : Exception()
    private class Unknown : Exception()
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pending") { result.success(active?.pending != null); return }
        if (call.method != "set") { result.notImplemented(); return }
        if (closed || workerUnavailable) { result.success(mapOf("outcome" to "unknown")); return }
        if (Build.VERSION.SDK_INT < 30) { result.success(mapOf("outcome" to "unsupported")); return }
        if (pending != null) { result.success(mapOf("outcome" to "busy")); return }
        val mediaKind = try { MediaKind.from(call.argument<Any>("mediaKind")) } catch (_: IllegalArgumentException) {
            result.success(mapOf("outcome" to "unsupported")); return
        }
        val id = call.argument<Number>("id")?.toLong()
        val version = call.argument<String>("libraryVersion")
        val added = call.argument<Number>("addedSeconds")?.toLong()
        val taken = call.argument<Number>("takenMs")?.toLong()
        val width = call.argument<Number>("width")?.toInt()
        val height = call.argument<Number>("height")?.toInt()
        val value = call.argument<Boolean>("value")
        if (id == null || id <= 0 || version.isNullOrEmpty() || added == null ||
            taken == null || width == null || height == null || value == null ||
            call.argument<String>("volume") != MediaStore.VOLUME_EXTERNAL_PRIMARY) {
            result.success(mapOf("outcome" to "stale")); return
        }
        if (!gate.acquire(this)) { result.success(mapOf("outcome" to "busy")); return }
        val code = allocateRequestCode()
        if (code == null) {
            gate.release(this)
            result.success(mapOf("outcome" to "unsupported")); return
        }
        val request = Request(id, mediaKind, version, added, taken, width, height, value, result, code)
        pending = request
        active = this
        val signal = beginRead(request)
        worker.execute {
            try {
                val before = read(request, signal)
                if (before == value) {
                    main.post { finish(request, "confirmed", before) }
                } else {
                    val intent = MediaStore.createFavoriteRequest(activity.contentResolver, listOf(request.uri), value)
                    main.post {
                        if (pending !== request || closed) return@post
                        try {
                            endRead()
                            launched = true
                            activity.startIntentSenderForResult(intent.intentSender, request.requestCode, null, 0, 0, 0)
                        } catch (_: Exception) {
                            finish(request, "unknown")
                        }
                    }
                }
            } catch (error: Exception) {
                main.post { finish(request, classify(error)) }
            }
        }
    }
    private fun read(request: Request, cancellation: CancellationSignal? = null): Boolean {
        request.mediaKind.requireRead(activity)
        if (MediaStore.getVersion(activity, MediaStore.VOLUME_EXTERNAL_PRIMARY) != request.version) throw Stale()
        val columns = arrayOf("date_added", "datetaken", "width", "height", "is_pending", "is_trashed", "is_favorite")
        val value = activity.contentResolver.query(request.uri, columns, null, null, null, cancellation)?.use { cursor ->
            if (!cursor.moveToFirst()) throw Stale()
            if (cursor.getLong(0) != request.added || cursor.getLong(1) != request.taken ||
                cursor.getInt(2) != request.width || cursor.getInt(3) != request.height ||
                cursor.getInt(4) != 0 || cursor.getInt(5) != 0) throw Stale()
            if (cursor.isNull(6)) throw Unknown()
            when (cursor.getInt(6)) { 0 -> false; 1 -> true; else -> throw Unknown() }
        } ?: throw Unknown()
        if (MediaStore.getVersion(activity, MediaStore.VOLUME_EXTERNAL_PRIMARY) != request.version) throw Stale()
        return value
    }
    fun activityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode !in FIRST_REQUEST..LAST_REQUEST) return false
        val owner = active
        if (owner != null && owner !== this) return owner.activityResult(requestCode, resultCode)
        val request = pending ?: return true
        if (request.requestCode != requestCode || !launched) return true
        cancelRecovery()
        launched = false
        val signal = beginRead(request)
        worker.execute {
            try {
                val current = read(request, signal)
                val outcome = when {
                    resultCode == Activity.RESULT_CANCELED -> "cancelled"
                    resultCode != Activity.RESULT_OK -> "unknown"
                    current == request.value -> "confirmed"
                    else -> "unknown"
                }
                main.post { finish(request, outcome, current, outcome == "confirmed") }
            } catch (error: Exception) {
                main.post { finish(request, classify(error, afterRequest = true)) }
            }
        }
        if (closed) worker.shutdown()
        return true
    }
    fun paused() {
        resumed = false
        if (launched) leftForConfirmation = true
        cancelRecovery()
    }
    fun resumed() {
        resumed = true
        recoverMissingResult()
    }
    fun windowFocusChanged(hasFocus: Boolean) {
        if (hasFocus) recoverMissingResult() else {
            if (launched) leftForConfirmation = true
            cancelRecovery()
        }
    }
    // Focus and a readable field cannot prove that a system write has ended.
    // Report uncertainty once, retaining the process lease until its result.
    private fun recoverMissingResult() {
        val request = pending ?: return
        if (!resumed || !activity.hasWindowFocus() || !leftForConfirmation || !launched || closed || recovery != null || request.result == null) return
        val start = Runnable {
            recovery = null
            if (pending !== request || !resumed || !activity.hasWindowFocus() || !launched || closed) return@Runnable
            val reply = request.result
            request.result = null
            reply?.success(mapOf("outcome" to "unknown", "pending" to true))
        }
        recovery = start
        main.postDelayed(start, 500)
    }
    private fun cancelRecovery() {
        recovery?.let { main.removeCallbacks(it) }
        recovery = null
    }
    // Bound provider work before launch and after an actual Activity result.
    // Never time out a live confirmation. If a provider stalls, retire this
    // adapter's worker so future requests cannot queue forever behind it.
    private fun beginRead(request: Request): CancellationSignal {
        endRead()
        val signal = CancellationSignal()
        readSignal = signal
        val deadline = Runnable {
            if (pending === request) {
                workerUnavailable = true
                finish(request, "unknown")
            }
        }
        readDeadline = deadline
        main.postDelayed(deadline, 5000)
        return signal
    }
    private fun endRead() {
        readDeadline?.let { main.removeCallbacks(it) }
        readDeadline = null
        val signal = readSignal
        readSignal = null
        if (signal != null) cancelOffMain(signal)
    }
    private fun cancelOffMain(signal: CancellationSignal) {
        // Cancellation can itself perform provider IPC. Never wait on it on
        // the Activity thread, including timeout, focus loss and cleanup.
        Thread({ try { signal.cancel() } catch (_: Exception) {} }, "favorite-cancel").apply {
            isDaemon = true
            start()
        }
    }
    private fun classify(error: Exception, afterRequest: Boolean = false) = when (error) {
        is SecurityException -> "permission"
        is Stale -> "stale"
        is Unknown -> "unknown"
        else -> if (afterRequest) "unknown" else "failed"
    }
    private fun finish(request: Request, outcome: String, value: Boolean? = null, changed: Boolean = false) {
        if (pending !== request) return
        pending = null
        launched = false
        leftForConfirmation = false
        gate.release(this)
        if (active === this) active = null
        val reply = request.result
        request.result = null
        if (!closed) reply?.success(mapOf("outcome" to outcome, "value" to value, "changed" to changed))
        // Retire and complete before cancellation can contact the provider.
        endRead()
        cancelRecovery()
    }
    fun close() {
        closed = true
        pending?.result = null
        cancelRecovery()
        // A destroyed engine is not cancellation of an already launched system
        // request. Its new Activity routes the matching result back to this owner.
        // Reads that have not launched cannot create a new request after cleanup.
        if (!launched) {
            pending?.let { finish(it, "unknown") }
            worker.shutdown()
        }
    }
    companion object {
        // Main-thread state, retained only while an actual request is outstanding.
        private var active: SystemFavorites? = null
        private const val FIRST_REQUEST = 0x5000
        private const val LAST_REQUEST = 0x7fff
        // Never reuse within the process, including Activity recreation. A late
        // result for a retired request cannot complete a newer confirmation.
        private var nextRequest = FIRST_REQUEST
        @Synchronized private fun allocateRequestCode(): Int? =
            if (nextRequest <= LAST_REQUEST) nextRequest++ else null
    }
}
