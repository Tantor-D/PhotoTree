package io.github.tantor_d.phototree

/** Public libc operations; opaque handles remain entirely inside this adapter. */
object NativeDirectories {
    init { System.loadLibrary("phototree_directories") }
    external fun begin(root: ByteArray, path: ByteArray): Long
    external fun create(handle: Long, name: ByteArray): Int
    external fun verify(handle: Long): Boolean
    external fun end(handle: Long)
    external fun entries(root: ByteArray, path: ByteArray): Array<ByteArray>?
    external fun removeEmpty(root: ByteArray, path: ByteArray): Int
    external fun read(root: ByteArray, path: ByteArray): Int
}
