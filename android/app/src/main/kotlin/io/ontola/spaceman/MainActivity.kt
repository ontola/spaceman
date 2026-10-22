package io.ontola.spaceman

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Exposes "All files access" to Dart. Without it, Android only lets the app
/// see its own files and media, so a scan would show next to nothing.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spaceman/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAccess" -> result.success(hasAccess())
                    "requestAccess" -> {
                        requestAccess()
                        result.success(null)
                    }
                    "storageRoot" ->
                        result.success(Environment.getExternalStorageDirectory().absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    /// Android 11+ grants this only from Settings; the app sees the result
    /// when it resumes. Older versions show the regular permission dialog.
    private fun requestAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivity(intent)
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                ),
                1,
            )
        }
    }
}
