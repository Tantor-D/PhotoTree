package io.github.tantor_d.phototree

/** Process-owned exclusion: an Activity may die while its system work continues. */
class DocumentPickerGate {
    fun acquire(requester: Any): Boolean = synchronized(lock) {
        if (owner != null) false else { owner = requester; true }
    }
    fun release(requester: Any) = synchronized(lock) { if (owner === requester) owner = null }
    companion object {
        private val lock = Any()
        private var owner: Any? = null
    }
}
