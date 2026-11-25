package io.github.tantor_d.phototree

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.UUID
import android.os.Environment
import android.os.SystemClock

/** Local tree grants and one bounded native creation/association session. */
class DirectoryAccess(private val activity: Activity, private val gate: DocumentPickerGate) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val records = activity.getSharedPreferences("directory_grants", 0)
    private var pending: MethodChannel.Result? = null
    private var expected: String? = null
    @Volatile private var closed = false
    private data class Live(val token: String, val path: String, val handle: Long, val deadline: Long)
    private var live: Live? = null // Accessed only on worker.
    private val root: ByteArray get() = Environment.getExternalStorageDirectory().canonicalPath.toByteArray(Charsets.UTF_8)
    private fun releaseLive() { live?.let { NativeDirectories.end(it.handle) }; live = null }
    private fun currentGrant(path: String): Boolean = records.all.entries.any { (savedPath, value) ->
        if (!path.startsWith(savedPath) || value !is String) false else try {
            val uri = Uri.parse(value)
            treePath(uri) == savedPath && activity.contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }
        } catch (_: Exception) { false }
    }
    private fun session(token: String?): Live? {
        val value = live ?: return null
        if (SystemClock.elapsedRealtime() >= value.deadline || !currentGrant(value.path)) { releaseLive(); return null }
        return if (token == value.token) value else null
    }
    private fun nativeCall(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val answer = try { work() } catch (_: Exception) { null } catch (_: LinkageError) { null }
            main.post { if (!closed) result.success(answer) }
        }
    }
    companion object { const val REQUEST = 7051 }
    private fun path(call: MethodCall): String? {
        if (call.argument<String>("volume") != "external_primary") return null
        val path = call.argument<String>("path") ?: return null
        if (!path.endsWith('/')) return null
        return if (validPath(path.dropLast(1))) path else null
    }
    private fun validPath(path: String): Boolean {
        val parts = path.split('/')
        return parts.firstOrNull() in listOf("Pictures", "DCIM") && parts.all {
            it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') && !it.contains('\u0000')
        }
    }
    private fun treePath(uri: Uri): String? {
        if (uri.scheme != "content" || uri.authority != "com.android.externalstorage.documents" || !DocumentsContract.isTreeUri(uri)) return null
        val id = DocumentsContract.getTreeDocumentId(uri)
        if (!id.startsWith("primary:")) return null
        val path = id.removePrefix("primary:")
        return if (validPath(path)) "$path/" else null
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method in listOf("create", "verify", "end")) {
            nativeCall(result) {
                val current = session(call.argument<String>("token"))
                when (call.method) {
                    "end" -> { if (current != null) releaseLive(); true }
                    "verify" -> {
                        val valid = current != null && NativeDirectories.verify(current.handle)
                        if (current != null && !valid) releaseLive()
                        valid
                    }
                    else -> {
                        val name = call.argument<String>("name") ?: ""
                        val valid = name.isNotEmpty() && name == name.trim() && name.codePointCount(0, name.length) <= 64 &&
                            !name.startsWith('.') && !name.contains('/') && !name.contains('\\') &&
                            name.codePoints().noneMatch { it < 32 || it in 127..159 || it == 0x2028 || it == 0x2029 }
                        if (current == null) "unknown" else if (!valid) "failed" else when (NativeDirectories.create(current.handle, name.toByteArray(Charsets.UTF_8))) {
                            0 -> "created"; 1 -> "conflict"; 2 -> "failed"; else -> "unknown"
                        }
                    }
                }
            }
            return
        }
        val path = path(call)
        if (path == null) {
            if (call.method == "authorize") result.success("rejected")
            else result.success(answer("unsupported", "仅支持主共享存储 Pictures/ 或 DCIM/ 内的规范目录"))
            return
        }
        when (call.method) {
            "begin" -> nativeCall(result) {
                if (live != null || !currentGrant(path)) null else {
                    val handle = NativeDirectories.begin(root, path.toByteArray(Charsets.UTF_8))
                    if (handle == 0L) null else {
                        val token = UUID.randomUUID().toString()
                        live = Live(token, path, handle, SystemClock.elapsedRealtime() + 120000)
                        main.postDelayed({ if (!closed) worker.execute { if (live?.token == token) releaseLive() } }, 120000)
                        token
                    }
                }
            }
            "readDirectory" -> nativeCall(result) {
                if (!currentGrant(path)) mapOf("contents" to "needsAuthorization", "reason" to "目录状态待核对，请重新授权")
                else when (NativeDirectories.read(root, path.toByteArray(Charsets.UTF_8))) {
                    0 -> mapOf("contents" to "empty", "reason" to "已核对真实空目录 · 0 项")
                    1 -> mapOf("contents" to "content", "reason" to "目录含内容，尚无可访问照片；可刷新媒体索引")
                    2 -> mapOf("contents" to "missing", "reason" to "已确认目录缺失；私有归类保留")
                    else -> mapOf("contents" to "failed", "reason" to "目录查询失败，状态待核对")
                }
            }
            "inspect" -> worker.execute {
                val report = inspect(path)
                main.post { if (!closed) result.success(report) }
            }
            "authorize" -> {
                if (!gate.acquire(this)) { result.success("busy"); return }
                pending = result; expected = path
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:${path.dropLast(1)}"))
                    }, REQUEST)
                } catch (_: Exception) { finish("interrupted") }
            }
            else -> result.notImplemented()
        }
    }
    private fun answer(status: String, reason: String, readable: Boolean = false, listable: Boolean = false): Map<String, Any> =
        mapOf("status" to status, "reason" to reason, "readable" to readable, "listable" to listable)
    private fun inspect(path: String): Map<String, Any> {
        val saved = records.getString(path, null) ?: return answer("needsAuthorization", "尚未授权此目录")
        try {
            val uri = Uri.parse(saved)
            if (treePath(uri) != path) return answer("unavailable", "保存的目录身份无法确认，请重新授权")
            val grant = activity.contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri }
            if (grant == null || !grant.isReadPermission || !grant.isWritePermission) return answer("revoked", "目录授权已失效，请重新授权")
            val id = DocumentsContract.getTreeDocumentId(uri)
            val document = DocumentsContract.buildDocumentUriUsingTree(uri, id)
            val exists = activity.contentResolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { c ->
                c.moveToFirst() && c.getString(0) == id && c.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR
            } ?: false
            if (!exists) return answer("unavailable", "目录已移动、删除或无法确认，请重新授权")
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, id)
            val listed = activity.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { c -> c.count; true } ?: false
            if (!listed) return answer("unavailable", "目录可读取，但无法列举其内容", readable = true)
            return answer("available", "目录授权有效，可读取和列举；路径相同不证明目录对象未被替换", true, true)
        } catch (_: SecurityException) { return answer("revoked", "目录授权已失效，请重新授权") }
        catch (_: Exception) { return answer("unavailable", "目录状态无法确认，请重试或重新授权") }
    }
    fun activityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST) return false
        if (pending == null) return true
        if (code == Activity.RESULT_CANCELED) { finish("cancelled"); return true }
        val uri = data?.data
        try {
            if (code != Activity.RESULT_OK || uri == null || treePath(uri) != expected) { finish("rejected"); return true }
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (flags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) { finish("rejected"); return true }
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (!records.edit().putString(expected, uri.toString()).commit()) { finish("interrupted"); return true }
            finish("granted")
        } catch (_: Exception) { finish("rejected") }
        return true
    }
    private fun finish(value: String) {
        val reply = pending; pending = null; expected = null
        gate.release(this); reply?.success(value)
    }
    fun close() { closed = true; finish("interrupted"); worker.execute { releaseLive() }; worker.shutdown() }
}
