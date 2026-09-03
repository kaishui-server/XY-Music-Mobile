package com.xymusic.mobile

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 本地音乐扫描的存储权限桥。
 *
 * 设计参考 MusicFree 的 UtilsModule.kt：完全使用 Android 原生 API 按
 * 系统版本分支处理，不经过 permission_handler 等插件层，规避插件在
 * Android 13 以下对音频/存储权限「假授权」（request 直接返回 granted
 * 但实际未授予）等问题——这正是部分机型（如 vivo NEX 双屏版
 * Android 8.1）扫描本地音乐时报「无法读取文件夹」死循环的根源。
 *
 * - API >= 30：检查 Environment.isExternalStorageManager()，未授权时
 *   跳转「所有文件访问」系统设置页；
 * - API 23-29：运行时弹框申请 READ/WRITE_EXTERNAL_STORAGE，结果经
 *   onRequestPermissionsResult 异步回传；
 * - API < 23：安装时已在清单授予，直接返回 true。
 */
object StoragePermissionBridge {
    private const val CHANNEL = "com.xymusic.mobile/storage_permission"
    private const val PERMISSION_REQUEST = 4219
    private const val READ = Manifest.permission.READ_EXTERNAL_STORAGE
    private const val WRITE = Manifest.permission.WRITE_EXTERNAL_STORAGE

    private var pendingResult: MethodChannel.Result? = null

    fun register(activity: MainActivity, flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> result.success(check(activity))
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "request" -> request(activity, result)
                    "openAppSettings" -> {
                        openAppSettings(activity)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 当前是否具备按文件路径读取共享存储的权限。 */
    fun check(activity: Activity): Boolean {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                Environment.isExternalStorageManager()
            // Android 10（API 29）：WRITE 在清单中 maxSdkVersion=28，系统
            // 视为未声明、永远 denied；且 WRITE 自 Android 10 起已废弃，
            // 按路径读取只需 READ。此前同时要求 READ+WRITE 导致用户在
            // 弹框里点了「允许」仍被判为拒绝，反复跳系统设置页死循环。
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                granted(activity, READ)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                granted(activity, READ) && granted(activity, WRITE)
            else -> true
        }
    }

    /**
     * 发起权限申请。
     *
     * 返回值语义：
     * - true：已授权（低版本弹框后立即授予，或 API < 23 安装时已授予）；
     * - false：低版本弹框被拒绝；
     * - null：API >= 30，已跳转「所有文件访问」设置页，授权结果需等
     *   应用回到前台后由 Dart 侧重新 check()。
     */
    private fun request(activity: MainActivity, result: MethodChannel.Result) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${activity.packageName}"),
                )
                activity.startActivity(intent)
                result.success(null)
            }
            // Android 10：只申请 READ（WRITE 清单未声明，申请必然被系统
            // 自动拒绝，会把用户已点的「允许」误判为拒绝）。
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                if (pendingResult != null) {
                    result.error("BUSY", "权限申请正在进行", null)
                    return
                }
                pendingResult = result
                ActivityCompat.requestPermissions(activity, arrayOf(READ), PERMISSION_REQUEST)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                if (pendingResult != null) {
                    result.error("BUSY", "权限申请正在进行", null)
                    return
                }
                pendingResult = result
                ActivityCompat.requestPermissions(activity, arrayOf(READ, WRITE), PERMISSION_REQUEST)
            }
            else -> result.success(true)
        }
    }

    /** 转发低版本 requestPermissions 的结果到 Flutter。 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val result = pendingResult ?: return
        pendingResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        result.success(granted)
    }

    /** 跳转本应用详情页（弹框被永久拒绝时的手动引导，MusicFree 同款）。 */
    private fun openAppSettings(activity: Activity) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${activity.packageName}"),
        )
        activity.startActivity(intent)
    }

    private fun granted(activity: Activity, permission: String): Boolean =
        ContextCompat.checkSelfPermission(activity, permission) ==
            PackageManager.PERMISSION_GRANTED
}
