package io.github.tantor_d.phototree

import android.content.ContentResolver
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Only the raw fields the plugin loses. No writes, arbitrary SQL or browsing rules. */
class MediaMetadata(private val context: Context, private val activityStartNanos: Long) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "acceptanceClock") {
            result.success(mapOf("activityConstructNanos" to activityStartNanos,
                "processStartElapsedMs" to android.os.Process.getStartElapsedRealtime(),
                "nativeNowNanos" to android.os.SystemClock.elapsedRealtimeNanos()))
            return
        }
        if (call.method == "playbackUri") {
            worker.execute {
                try {
                    val kind = MediaKind.from(call.argument<Any>("mediaKind"))
                    if (kind != MediaKind.VIDEO || call.argument<String>("volume") != MediaStore.VOLUME_EXTERNAL_PRIMARY) throw IllegalArgumentException()
                    kind.requireRead(context)
                    val version = call.argument<String>("libraryVersion")
                    if (version.isNullOrEmpty() || MediaStore.getVersion(context, MediaStore.VOLUME_EXTERNAL_PRIMARY) != version) throw IllegalStateException()
                    val uri = kind.uri(call.argument<Number>("id")?.toLong() ?: 0)
                    context.contentResolver.query(uri, arrayOf("date_added", "datetaken", "width", "height", "relative_path", "is_pending", "is_trashed"), null, null, null)?.use { c ->
                        if (!c.moveToFirst() || c.getInt(5) != 0 || c.getInt(6) != 0 || c.getString(4) != call.argument<String>("directory")) throw IllegalStateException()
                        for ((index, key) in listOf("addedSeconds", "takenMs", "width", "height").withIndex()) {
                            if (c.getLong(index) != call.argument<Number>(key)?.toLong()) throw IllegalStateException()
                        }
                    } ?: throw IllegalStateException()
                    context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { } ?: throw IllegalStateException()
                    kind.requireRead(context)
                    if (MediaStore.getVersion(context, MediaStore.VOLUME_EXTERNAL_PRIMARY) != version) throw IllegalStateException()
                    main.post { result.success(uri.toString()) }
                } catch (_: Exception) {
                    main.post { result.error("unavailable", "Video is no longer accessible", null) }
                }
            }
            return
        }
        if (call.method == "collectionRevision") {
            worker.execute {
                try {
                    val revision = MediaStore.getGeneration(context, MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    main.post { result.success(revision) }
                } catch (_: Exception) {
                    main.post { result.error("generation", "Media collection revision unavailable", null) }
                }
            }
            return
        }
        if (call.method == "version") {
            worker.execute {
                try {
                    val version = MediaStore.getVersion(context, MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    main.post { result.success(version) }
                } catch (_: Exception) {
                    main.post { result.error("version", "Media identity unavailable", null) }
                }
            }
            return
        }
        if (call.method != "page") { result.notImplemented(); return }
        val after = call.argument<Number>("afterId")?.toLong()
        if (after == null || after < 0) { result.error("query", "Invalid cursor", null); return }
        worker.execute {
            try {
                val columns = arrayOf("_id", "relative_path", "datetaken", "date_added", "width", "height", "is_favorite", "media_type", "duration")
                val args = Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "_id > ? AND is_pending = 0 AND is_trashed = 0 AND (media_type = ? OR media_type = ?)")
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(after.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(), MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString()))
                    putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf("_id"))
                    putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_ASCENDING)
                    putInt(ContentResolver.QUERY_ARG_LIMIT, 256)
                }
                val rows = ArrayList<Map<String, Any?>>()
                context.contentResolver.query(
                    MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), columns, args, null
                )?.use { cursor ->
                    while (cursor.moveToNext() && rows.size < 256) {
                        val directory = cursor.getString(1)
                        if (directory.isNullOrEmpty()) throw MissingDirectory()
                        rows.add(mapOf("id" to cursor.getLong(0), "directory" to directory,
                            "volume" to MediaStore.VOLUME_EXTERNAL_PRIMARY, "takenMs" to cursor.getLong(2),
                            "addedSeconds" to cursor.getLong(3), "width" to cursor.getInt(4), "height" to cursor.getInt(5),
                            "mediaKind" to when (cursor.getInt(7)) { MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> "image"; MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> "video"; else -> throw IllegalStateException("Unknown media kind") },
                            "durationMs" to if (cursor.isNull(8) || cursor.getLong(8) < 0) null else cursor.getLong(8),
                            "systemFavorite" to if (cursor.isNull(6)) null else when (cursor.getInt(6)) { 0 -> false; 1 -> true; else -> null }))
                    }
                } ?: throw IllegalStateException("No query cursor")
                main.post { result.success(rows) }
            } catch (_: MissingDirectory) {
                main.post { result.error("directory", "Missing album directory", null) }
            } catch (_: SecurityException) {
                main.post { result.error("permission", "Photo access changed", null) }
            } catch (_: Exception) {
                main.post { result.error("query", "Unable to read photo metadata", null) }
            }
        }
    }
    private class MissingDirectory : Exception()
    fun close() { worker.shutdown() }
}
