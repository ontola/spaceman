package io.ontola.spaceman

import android.Manifest
import android.app.AppOpsManager
import android.app.usage.StorageStatsManager
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Process
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Exposes "All files access" to Dart. Without it, Android only lets the app
/// see its own files and media, so a scan would show next to nothing.
///
/// Apps and their data live outside shared storage, where no file scan can
/// reach. Their sizes come from StorageStatsManager, which needs "Usage
/// access".
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
                    "hasUsageAccess" -> result.success(hasUsageAccess())
                    "requestUsageAccess" -> {
                        openSettings(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                        result.success(null)
                    }
                    "appSizes" -> Thread {
                        val apps = try {
                            appSizes()
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread {
                            if (apps == null) {
                                result.error("stats", "Could not read app sizes", null)
                            } else {
                                result.success(apps)
                            }
                        }
                    }.start()
                    "openAppInfo" -> {
                        openSettings(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            call.argument<String>("package"),
                        )
                        result.success(null)
                    }
                    "uninstall" -> {
                        val pkg = call.argument<String>("package")
                        startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg")))
                        result.success(null)
                    }
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

    private fun hasUsageAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val appOps = getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /// Size of every installed app: the app itself, its data (which
    /// includes the cache) and the cache alone. Also the totals of internal
    /// storage, so Dart can tell what is left for the system.
    private fun appSizes(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf("apps" to emptyList<Any>())
        }
        val stats = getSystemService(StorageStatsManager::class.java)
        val user = Process.myUserHandle()
        val uuid = StorageManager.UUID_DEFAULT
        val apps = packageManager.getInstalledApplications(0).mapNotNull { info ->
            try {
                val s = stats.queryStatsForPackage(uuid, info.packageName, user)
                mapOf(
                    "package" to info.packageName,
                    "label" to packageManager.getApplicationLabel(info).toString(),
                    "app" to s.appBytes,
                    "data" to s.dataBytes,
                    "cache" to s.cacheBytes,
                    "system" to ((info.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                        (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0),
                )
            } catch (e: Exception) {
                null
            }
        }
        return mapOf(
            "apps" to apps,
            "total" to stats.getTotalBytes(uuid),
            "free" to stats.getFreeBytes(uuid),
        )
    }

    private fun openSettings(action: String, pkg: String? = packageName) {
        try {
            startActivity(Intent(action, Uri.parse("package:$pkg")))
        } catch (e: Exception) {
            startActivity(Intent(action))
        }
    }
}
