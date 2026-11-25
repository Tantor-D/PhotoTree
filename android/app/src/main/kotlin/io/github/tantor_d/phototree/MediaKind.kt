package io.github.tantor_d.phototree

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore

/** One typed URI/permission mapping shared by the existing media adapters. */
internal enum class MediaKind(val wire: String) {
    IMAGE("image"), VIDEO("video");

    fun uri(id: Long): Uri {
        require(id > 0)
        val collection = when (this) {
            IMAGE -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            VIDEO -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        return ContentUris.withAppendedId(collection, id)
    }

    fun fullAccess(context: Context): Boolean {
        val permission = if (Build.VERSION.SDK_INT < 33) Manifest.permission.READ_EXTERNAL_STORAGE
            else if (this == IMAGE) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_MEDIA_VIDEO
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    fun requireRead(context: Context) {
        if (!fullAccess(context) && !(Build.VERSION.SDK_INT >= 34 &&
            context.checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED)) {
            throw SecurityException("Media permission changed")
        }
    }

    companion object {
        // Missing means historical image. Unknown explicit types never authorize an operation.
        fun from(value: Any?): MediaKind = when (value) {
            null, "image" -> IMAGE
            "video" -> VIDEO
            else -> throw IllegalArgumentException("Unknown media kind")
        }
    }
}
