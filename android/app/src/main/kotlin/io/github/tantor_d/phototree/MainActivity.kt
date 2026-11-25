package io.github.tantor_d.phototree

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val activityStartNanos = android.os.SystemClock.elapsedRealtimeNanos()
    private val pickerGate = DocumentPickerGate()
    private var physical: PhysicalMediaOps? = null
    private var physicalChannel: MethodChannel? = null
    private var directories: DirectoryAccess? = null
    private var directoryChannel: MethodChannel? = null
    private var backup: BackupFiles? = null
    private var backupChannel: MethodChannel? = null
    private var systemFavorites: SystemFavorites? = null
    private var systemFavoriteChannel: MethodChannel? = null
    private var metadata: MediaMetadata? = null
    private var channel: MethodChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        physical = PhysicalMediaOps(this, pickerGate)
        physicalChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tantor_d.phototree/physicalMedia")
        physicalChannel?.setMethodCallHandler(physical)
        systemFavorites = SystemFavorites(this, pickerGate)
        systemFavoriteChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tantor_d.phototree/systemFavorites")
        systemFavoriteChannel?.setMethodCallHandler(systemFavorites)
        backup = BackupFiles(this, pickerGate)
        directories = DirectoryAccess(this, pickerGate)
        directoryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tantor_d.phototree/directories")
        directoryChannel?.setMethodCallHandler(directories)
        backupChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tantor_d.phototree/backup")
        backupChannel?.setMethodCallHandler(backup)
        metadata = MediaMetadata(applicationContext, activityStartNanos)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.tantor_d.phototree/metadata")
        channel?.setMethodCallHandler(metadata)
    }
    override fun onPause() {
        physical?.paused()
        systemFavorites?.paused()
        super.onPause()
    }
    override fun onResume() {
        super.onResume()
        systemFavorites?.resumed()
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        physical?.windowFocusChanged(hasFocus)
        systemFavorites?.windowFocusChanged(hasFocus)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (backup?.permissionResult(requestCode) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (physical?.activityResult(requestCode, resultCode) == true) return
        if (systemFavorites?.activityResult(requestCode, resultCode) == true) return
        if (directories?.activityResult(requestCode, resultCode, data) == true) return
        if (backup?.activityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        physicalChannel?.setMethodCallHandler(null)
        physical?.close()
        systemFavoriteChannel?.setMethodCallHandler(null)
        systemFavorites?.close()
        directoryChannel?.setMethodCallHandler(null)
        directories?.close()
        backupChannel?.setMethodCallHandler(null)
        backup?.close()
        channel?.setMethodCallHandler(null)
        metadata?.close()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
