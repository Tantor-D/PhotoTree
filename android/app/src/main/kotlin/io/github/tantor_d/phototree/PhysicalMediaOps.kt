package io.github.tantor_d.phototree

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.os.Process
import android.content.ContentValues
import android.content.ContentUris
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.system.Os
import android.system.ErrnoException
import java.nio.ByteBuffer
import android.system.OsConstants
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.concurrent.Executors

/** System-authorized operations. Reconciliation only observes and never repeats a write. */
class PhysicalMediaOps(private val activity: Activity, private val gate: DocumentPickerGate) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = activity.contentResolver
    @Volatile private var pending: Pending? = null
    @Volatile private var closed = false
    private var busy = false
    private var launched = false
    private var leftForConfirmation = false
    private var recovery: Runnable? = null
    private val deadlines = java.util.IdentityHashMap<MethodChannel.Result, Runnable>()
    private val timedOut = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<MethodChannel.Result, Boolean>())
    private fun stopDeadline(result: MethodChannel.Result) { deadlines.remove(result)?.let { main.removeCallbacks(it) } }
    private fun startDeadline(result: MethodChannel.Result) {
        val timeout = Runnable {
            deadlines.remove(result)
            if (!closed && timedOut.add(result)) { result.success(answer("busy", reason = "系统操作仍在执行，请稍后仅核对结果")) }
            // Keep the gate while native work is still outstanding. A timeout is
            // not cancellation, and a second request must not overlap it.
        }
        deadlines[result] = timeout
        main.postDelayed(timeout, 30000)
    }
    private data class Pending(val snapshot: Map<String, Any?>, val kind: String, val target: String?, val result: MethodChannel.Result, val code: Int, val photos: List<Map<String, Any?>> = emptyList())
    private class State(val outcome: String, val reason: String? = null) : Exception()
    private fun answer(outcome: String, after: Map<String, Any?>? = null, reason: String? = null) = mapOf("outcome" to outcome, "after" to after, "reason" to reason)
    private fun fullAccess(kind: MediaKind = MediaKind.IMAGE) = kind.fullAccess(activity)
    private fun requireRead(kind: MediaKind = MediaKind.IMAGE) = kind.requireRead(activity)
    private fun requireFull() { if (!fullAccess()) throw State("permission", "删除整个相册需要完整照片读取权限，请重新授权并核对") }
    private fun mediaKind(snapshot: Map<*, *>) = MediaKind.from(snapshot["mediaKind"])
    private fun validPath(path: String?) = path != null && path.endsWith('/') && path.split('/').dropLast(1).let { parts ->
        parts.firstOrNull() in listOf("Pictures", "DCIM") && parts.all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') && !it.contains('\u0000') }
    }
    private fun uri(id: Long, mediaKind: MediaKind) = mediaKind.uri(id)
    private fun number(map: Map<*, *>, key: String) = (map[key] as? Number)?.toLong() ?: throw State("stale")
    private fun version() = MediaStore.getVersion(activity, MediaStore.VOLUME_EXTERNAL_PRIMARY)
    private fun digest(id: Long, mediaKind: MediaKind): String {
        val hash = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(uri(id, mediaKind))?.use { stream ->
            val buffer = ByteArray(65536)
            while (true) { val count = stream.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        } ?: throw State("unknown")
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    private val columns = arrayOf("_id", "relative_path", "_display_name", "_size", "mime_type", "date_modified", "generation_modified", "date_added", "datetaken", "width", "height", "is_pending", "is_trashed", "duration")
    private fun read(id: Long, mediaKind: MediaKind = MediaKind.IMAGE): Map<String, Any?>? {
        requireRead(mediaKind)
        val v = version()
        val cursor = resolver.query(uri(id, mediaKind), columns, null, null, null) ?: throw State("unknown")
        val result = cursor.use { c ->
            if (!c.moveToFirst()) return@use null
            if (c.getInt(11) != 0 || c.getInt(12) != 0 || c.getString(4)?.startsWith(mediaKind.wire + "/") != true) throw State("stale")
            mapOf<String, Any?>("id" to c.getLong(0), "volume" to MediaStore.VOLUME_EXTERNAL_PRIMARY,
                "directory" to c.getString(1), "displayName" to c.getString(2), "size" to c.getLong(3),
                "mimeType" to c.getString(4), "modifiedSeconds" to c.getLong(5), "generationModified" to c.getLong(6),
                "addedSeconds" to c.getLong(7), "takenMs" to c.getLong(8), "width" to c.getLong(9), "height" to c.getLong(10), "libraryVersion" to v) + if (mediaKind == MediaKind.VIDEO) mapOf("mediaKind" to mediaKind.wire,
                    "durationMs" to if (c.isNull(13) || c.getLong(13) < 0) null else c.getLong(13)) else emptyMap()
        }
        if (version() != v) throw State("stale")
        if (result == null) return null
        val sum = digest(id, mediaKind)
        if (version() != v) throw State("stale")
        val stable = resolver.query(uri(id, mediaKind), arrayOf("generation_modified", "_size", "relative_path", "_display_name"), null, null, null)?.use { c ->
            c.moveToFirst() && c.getLong(0) == number(result, "generationModified") && c.getLong(1) == number(result, "size") && c.getString(2) == result["directory"] && c.getString(3) == result["displayName"]
        } ?: false
        if (!stable) throw State("stale")
        return result + ("sha256" to sum)
    }
    private fun same(left: Map<*, *>, right: Map<*, *>, keys: List<String>): Boolean = keys.all { key ->
        val a = if (key == "mediaKind") mediaKind(left) else left[key]; val b = if (key == "mediaKind") mediaKind(right) else right[key]
        if (a is Number && b is Number) a.toLong() == b.toLong() else a == b
    }
    private val baseKeys = listOf("id", "volume", "directory", "takenMs", "addedSeconds", "width", "height", "mediaKind")
    private val fullKeys = baseKeys + listOf("libraryVersion", "displayName", "size", "mimeType", "modifiedSeconds", "generationModified", "sha256", "durationMs")
    private fun validate(snapshot: Map<String, Any?>): Map<String, Any?> {
        val current = read(number(snapshot, "id"), mediaKind(snapshot)) ?: throw State("stale")
        if (!same(current, snapshot, fullKeys)) throw State("stale")
        return current
    }
    private fun tree(path: String): Uri {
        if (!validPath(path)) throw State("unsupported")
        val records = activity.getSharedPreferences("directory_grants", 0)
        for ((saved, raw) in records.all) {
            if (!path.startsWith(saved) || raw !is String) continue
            val tree = Uri.parse(raw)
            if (tree.authority != "com.android.externalstorage.documents" || !DocumentsContract.isTreeUri(tree)) continue
            if (DocumentsContract.getTreeDocumentId(tree) != "primary:${saved.dropLast(1)}") continue
            if (resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission && it.isWritePermission }) return tree
        }
        throw State("permission", "尚未授权此真实目录或授权已失效，请选择并授权该目录后重试")
    }
    private fun children(path: String): List<Pair<String, String>> {
        val tree = tree(path)
        val id = "primary:${path.dropLast(1)}"
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val exists = resolver.query(document, arrayOf("document_id", "mime_type"), null, null, null)?.use {
            it.moveToFirst() && it.getString(0) == id && it.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR
        } ?: false
        if (!exists) throw State("stale")
        return resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, id), arrayOf("_display_name", "mime_type"), null, null, null)?.use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0) to c.getString(1)) }
        } ?: throw State("unknown")
    }
    private fun directoryToken(path: String, parentOnly: Boolean = false): String {
        if (!validPath(path) || path in listOf("Pictures/", "DCIM/")) throw State("unsupported")
        val absolute = Environment.getExternalStorageDirectory().canonicalPath + "/" + path.dropLast(1)
        val parent = Os.lstat(absolute.substringBeforeLast('/'))
        if (!OsConstants.S_ISDIR(parent.st_mode)) throw State("stale")
        val prefix = "${parent.st_dev}:${parent.st_ino}"
        if (parentOnly) return prefix
        val child = Os.lstat(absolute)
        if (!OsConstants.S_ISDIR(child.st_mode)) throw State("stale")
        return "$prefix:${child.st_dev}:${child.st_ino}"
    }
    private fun album(path: String): Map<String, Any?> {
        requireFull()
        val token = directoryToken(path)
        val before = children(path)
        val root = Environment.getExternalStorageDirectory().canonicalPath.toByteArray(Charsets.UTF_8)
        val nativeNames = NativeDirectories.entries(root, path.toByteArray(Charsets.UTF_8))?.map {
            Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(it)).toString()
        } ?: throw State("unknown")
        if (nativeNames.toSet() != before.map { it.first }.toSet()) throw State("stale")
        if (before.any { !it.second.startsWith("image/") } || before.map { it.first }.toSet().size != before.size) throw State("unsupported")
        val ids = resolver.query(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), arrayOf("_id"), "relative_path = ?", arrayOf(path), null)?.use { c -> buildList<Long> { while (c.moveToNext()) add(c.getLong(0)) } } ?: throw State("unknown")
        val photos = ids.map { read(it) ?: throw State("stale") }
        if (photos.map { it["displayName"] }.toSet() != before.map { it.first }.toSet() || photos.size != before.size || children(path).toSet() != before.toSet() || directoryToken(path) != token) throw State("stale")
        return mapOf("outcome" to "confirmed", "photos" to photos, "empty" to photos.isEmpty(), "directoryToken" to token)
    }
    private fun reconcile(snapshot: Map<String, Any?>, kind: String, target: String?, knownEnded: Boolean = false): Map<String, Any?> {
        requireRead(mediaKind(snapshot))
        if (version() != snapshot["libraryVersion"]) return answer("unknown")
        val current = read(number(snapshot, "id"), mediaKind(snapshot))
        if (kind == "delete") {
            if (current != null) return answer(if (knownEnded && same(current, snapshot, fullKeys)) "failed" else "unknown")
            if (!fullAccess(mediaKind(snapshot))) return answer("unknown")
            val path = snapshot["directory"] as? String
            val name = snapshot["displayName"] as? String
            if (!validPath(path) || name.isNullOrEmpty() || name.contains('/') || name.contains('\\') || name.contains('\u0000')) return answer("unknown")
            val absolute = Environment.getExternalStorageDirectory().canonicalPath + "/" + path + name
            val absent = try { Os.lstat(absolute); false } catch (error: ErrnoException) {
                error.errno == OsConstants.ENOENT && try { OsConstants.S_ISDIR(Os.lstat(absolute.substringBeforeLast('/')).st_mode) } catch (_: Exception) { false }
            }
            return answer(if (absent) "confirmed" else "unknown")
        }
        if (snapshot["directory"] == target && current != null && same(current, snapshot, fullKeys)) return answer("unchanged", current)
        if (current == null || !same(current, snapshot, listOf("id", "volume", "libraryVersion", "size", "mimeType", "takenMs", "addedSeconds", "width", "height", "sha256", "mediaKind", "durationMs"))) return answer("unknown")
        val oldPath = Environment.getExternalStorageDirectory().canonicalPath + "/" + snapshot["directory"] + snapshot["displayName"]
        val oldAbsent = try { Os.lstat(oldPath); false } catch (e: ErrnoException) { e.errno == OsConstants.ENOENT }
        return if (current["directory"] == target && oldAbsent) answer("confirmed", current) else answer(if (knownEnded && same(current, snapshot, fullKeys)) "failed" else "unknown")
    }
    private fun canWrite(uri: Uri): Boolean = activity.checkUriPermission(
        uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    ) == PackageManager.PERMISSION_GRANTED
    private fun move(snapshot: Map<String, Any?>, target: String) {
                    val names = children(target).map { it.first.lowercase(java.util.Locale.ROOT) }.toSet()
                    val original = snapshot["displayName"] as? String ?: throw State("stale")
                    if (original.isEmpty() || original.contains('/') || original.contains('\\') || original.contains('\u0000')) throw State("stale")
                    val dot = original.lastIndexOf('.')
                    val stem = if (dot > 0) original.substring(0, dot) else original
                    val ext = if (dot > 0) original.substring(dot) else ""
                    var chosen = original; var suffix = 1
                    while (chosen.lowercase(java.util.Locale.ROOT) in names) {
                        if (suffix > 9999) throw State("failed")
                        chosen = "$stem (${suffix++})$ext"
                    }
                    // Normal Android move: the provider also resolves collisions.
                    // Its final existence check and rename are not atomic against
                    // another app creating a destination in that last window.
                    resolver.update(uri(number(snapshot, "id"), mediaKind(snapshot)), ContentValues().apply {
                        put(MediaStore.MediaColumns.RELATIVE_PATH, target)
                        put(MediaStore.MediaColumns.DISPLAY_NAME, chosen)
                    }, null, null)
    }
    private fun classify(error: Exception) = when (error) { is State -> error.outcome; is SecurityException -> "permission"; else -> "unknown" }
    private fun complete(result: MethodChannel.Result, reply: Any?) { main.post { stopDeadline(result); busy = false; gate.release(this); if (active === this) active = null; if (!timedOut.remove(result) && !closed) result.success(reply) } }
    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        startDeadline(result)
        worker.execute { val reply = try { work() } catch (e: Exception) { answer(classify(e), reason = (e as? State)?.reason) } catch (_: LinkageError) { answer("unsupported") }; complete(result, reply) }
    }
    @Suppress("UNCHECKED_CAST")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed || busy) { result.success(answer("busy")); return }
        if (call.method !in listOf("prepare", "inspectAlbum", "executePhoto", "reconcilePhoto", "deleteEmptyAlbum", "reconcileEmptyAlbum", "authorizePhotos", "authorizationState")) { result.notImplemented(); return }
        if (!gate.acquire(this)) { result.success(answer("busy")); return }
        busy = true
        active = this
        if (call.method == "authorizePhotos") {
            val photos = call.argument<List<Map<String, Any?>>>("photos")
            if (photos == null || photos.isEmpty() || photos.size > 500 ||
                photos.map { mediaKind(it) to it["id"] }.toSet().size != photos.size) {
                complete(result, answer("stale")); return
            }
            val code = nextCode()
            if (code == null) { complete(result, answer("unsupported")); return }
            val request = Pending(emptyMap(), "authorize", null, result, code, photos)
            pending = request
            startDeadline(result)
            worker.execute {
                try {
                    photos.forEach { validate(it) }
                    val missing = photos.map { uri(number(it, "id"), mediaKind(it)) }.filter { !canWrite(it) }
                    if (missing.isEmpty()) {
                        pending = null
                        complete(result, answer(if (closed) "unknown" else "confirmed"))
                    } else {
                        val intent = MediaStore.createWriteRequest(resolver, missing)
                        main.post {
                            if (closed || timedOut.contains(result)) {
                                pending = null; complete(result, answer("unknown"))
                            } else if (pending === request) try {
                                stopDeadline(result); launched = true
                                activity.startIntentSenderForResult(intent.intentSender, code, null, 0, 0, 0)
                            } catch (_: Exception) {
                                launched = false; pending = null; complete(result, answer("unknown"))
                            }
                        }
                    }
                } catch (e: Exception) { pending = null; complete(result, answer(classify(e))) }
            }
            return
        }
        if (call.method == "executePhoto") {
            val snapshot = call.argument<Map<String, Any?>>("snapshot")
            val kind = call.argument<String>("kind")
            val target = call.argument<String>("targetDirectory")
            if (snapshot == null || kind !in listOf("move", "delete")) { complete(result, answer("stale")); return }
            if (call.argument<Boolean>("authorized") == true) {
                run(result) {
                    if (closed) throw State("unknown")
                    validate(snapshot)
                    if (kind == "move" && snapshot["directory"] == target) {
                        return@run answer("unchanged", snapshot)
                    }
                    val mediaUri = uri(number(snapshot, "id"), mediaKind(snapshot))
                    if (!canWrite(mediaUri)) throw State("permission")
                    if (kind == "move") {
                        if (!validPath(target)) throw State("unsupported")
                        move(snapshot, target!!)
                    } else {
                        // Application-owned per-item execution retains the journal and
                        // cancel-before-next-item boundary. Never retry via a prompt.
                        resolver.delete(mediaUri, null, null)
                    }
                    reconcile(snapshot, kind!!, target, knownEnded = true)
                }
                return
            }
            val code = nextCode()
            if (code == null) { complete(result, answer("unsupported")); return }
            val request = Pending(snapshot, kind!!, target, result, code)
            pending = request
            startDeadline(result)
            worker.execute {
                try {
                    validate(snapshot)
                    if (kind == "move") {
                        if (!validPath(target)) throw State("unsupported")
                        if (snapshot["directory"] == target) { pending = null; complete(result, answer("unchanged", snapshot)); return@execute }
                        children(target!!)
                    }
                    val intent = if (kind == "move") MediaStore.createWriteRequest(resolver, listOf(uri(number(snapshot, "id"), mediaKind(snapshot)))) else MediaStore.createDeleteRequest(resolver, listOf(uri(number(snapshot, "id"), mediaKind(snapshot))))
                    main.post { if (closed || timedOut.contains(result)) { pending = null; complete(result, answer("unknown")) } else if (pending === request) try { stopDeadline(result); launched = true; activity.startIntentSenderForResult(intent.intentSender, code, null, 0, 0, 0) } catch (_: Exception) { pending = null; complete(result, answer("unknown")) } }
                } catch (e: Exception) { pending = null; complete(result, answer(classify(e), reason = (e as? State)?.reason)) }
            }
            return
        }
        run(result) {
            when (call.method) {
                "authorizationState" -> answer("confirmed") // Acquiring the gate proves no old request remains.
                "prepare" -> {
                    val input = call.argument<List<Map<String, Any?>>>("photos") ?: throw State("stale")
                    if (input.isEmpty() || input.size > 500 || call.argument<String>("libraryVersion") != version()) throw State("stale")
                    val photos = input.map { p -> val current = read(number(p, "id"), mediaKind(p)) ?: throw State("stale"); if (!same(p, current, baseKeys)) throw State("stale"); current }
                    if (photos.map { mediaKind(it) to it["id"] }.toSet().size != photos.size) throw State("stale")
                    val target = call.argument<String>("targetDirectory")
                    if (target != null) {
                        if (!validPath(target)) throw State("unsupported")
                        if (photos.any { it["directory"] != target }) children(target)
                    }
                    mapOf("outcome" to "confirmed", "photos" to photos)
                }
                "inspectAlbum" -> { if (call.argument<String>("volume") != MediaStore.VOLUME_EXTERNAL_PRIMARY) throw State("unsupported"); album(call.argument<String>("path") ?: "") }
                "reconcileEmptyAlbum" -> {
                    if (call.argument<String>("volume") != MediaStore.VOLUME_EXTERNAL_PRIMARY) throw State("unsupported")
                    val path = call.argument<String>("path") ?: ""
                    tree(path) // A revoked grant cannot prove absence.
                    val token = call.argument<String>("directoryToken") ?: throw State("stale")
                    if (directoryToken(path, true) != token.split(':').take(2).joinToString(":")) throw State("stale")
                    val root = Environment.getExternalStorageDirectory().canonicalPath.toByteArray(Charsets.UTF_8)
                    answer(when (NativeDirectories.read(root, path.toByteArray(Charsets.UTF_8))) { 2 -> "confirmed"; 0, 1 -> if (directoryToken(path) == token) "failed" else "stale"; else -> "unknown" })
                }
                "deleteEmptyAlbum" -> {
                    requireFull()
                    if (call.argument<String>("volume") != MediaStore.VOLUME_EXTERNAL_PRIMARY) throw State("unsupported")
                    val path = call.argument<String>("path") ?: ""
                    if (!validPath(path) || path in listOf("Pictures/", "DCIM/")) throw State("unsupported")
                    val token = call.argument<String>("directoryToken") ?: throw State("stale")
                    if (children(path).isNotEmpty() || directoryToken(path) != token) throw State("stale")
                    val root = Environment.getExternalStorageDirectory().canonicalPath.toByteArray(Charsets.UTF_8)
                    val bytes = path.toByteArray(Charsets.UTF_8)
                    when (NativeDirectories.removeEmpty(root, bytes)) { 0 -> answer(if (NativeDirectories.read(root, bytes) == 2) "confirmed" else "unknown"); 1 -> answer("stale"); 2 -> answer("permission"); else -> answer("unknown") }
                }
                else -> reconcile(call.argument<Map<String, Any?>>("snapshot") ?: throw State("stale"), call.argument<String>("kind") ?: "", call.argument<String>("targetDirectory"))
            }
        }
    }
    fun activityResult(code: Int, resultCode: Int): Boolean {
        if (code !in FIRST..LAST) return false
        val owner = active
        if (owner != null && owner !== this) return owner.activityResult(code, resultCode)
        val request = pending ?: return true
        if (request.code != code) return true
        pending = null
        launched = false
        leftForConfirmation = false
        recovery?.let { main.removeCallbacks(it) }; recovery = null
        run(request.result) {
            if (resultCode == Activity.RESULT_CANCELED) answer("cancelled")
            else if (resultCode != Activity.RESULT_OK) answer("unknown")
            else if (request.kind == "authorize") {
                if (closed) return@run answer("unknown")
                request.photos.forEach {
                    validate(it)
                    if (!canWrite(uri(number(it, "id"), mediaKind(it)))) throw State("permission")
                }
                answer("confirmed")
            } else {
                if (request.kind == "move") {
                    // Authorization alone must not start a new write for a destroyed owner.
                    if (closed) return@run answer("unknown")
                    validate(request.snapshot)
                    move(request.snapshot, request.target!!)
                }
                reconcile(request.snapshot, request.kind, request.target, knownEnded = true)
            }
        }
        if (closed) worker.shutdown()
        return true
    }
    fun paused() { if (launched) leftForConfirmation = true; recovery?.let { main.removeCallbacks(it) }; recovery = null }
    fun windowFocusChanged(focused: Boolean) {
        if (!focused) { if (launched) leftForConfirmation = true; return }
        val request = pending ?: return
        if (!launched || !leftForConfirmation || recovery != null) return
        val check = Runnable {
            recovery = null
            if (pending === request && activity.hasWindowFocus() && launched) {
                // Focus is not proof that the system request has ended. Preserve
                // its process lease until an explicit result, even if no callback arrives.
                if (!closed && timedOut.add(request.result)) request.result.success(answer("busy", reason = "系统确认结果尚未返回，请稍后仅核对结果"))
            }
        }
        recovery = check; main.postDelayed(check, 1000)
    }
    fun close() {
        closed = true
        deadlines.values.forEach { main.removeCallbacks(it) }; deadlines.clear()
        recovery?.let { main.removeCallbacks(it) }; recovery = null
        // Do not release an outstanding worker or system confirmation. A new
        // Activity routes its result back here; the old Flutter reply is retired.
        // Preflight work already queued is allowed to finish, but cannot launch.
        if (pending == null || !launched) worker.shutdown()
    }
    companion object {
        // Accessed on the Activity/main thread; retained only while the gate is held.
        private var active: PhysicalMediaOps? = null
        private const val FIRST = 0x3000
        private const val LAST = 0x4fff
        private var counter = FIRST
        @Synchronized private fun nextCode(): Int? = if (counter <= LAST) counter++ else null
    }
}
