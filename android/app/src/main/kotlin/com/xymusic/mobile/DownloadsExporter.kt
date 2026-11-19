package com.xymusic.mobile

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore

/**
 * 崩溃日志自动导出到公共下载目录（Download/XY Music/）。
 *
 * MediaStore.Downloads 免存储权限，所有 ROM 的文件管理器都能直接看到；
 * 用于「打开就闪退」场景——用户拿不到应用私有目录里的崩溃记录，但下次
 * 打开成功的那一次，下载目录里已经有上次闪退的完整日志文件。
 */
object DownloadsExporter {
    /**
     * 把文本文件写入 Download/XY Music/，返回面向用户的相对路径；
     * 失败返回 null（绝不能影响崩溃记录主流程）。
     */
    fun saveText(context: Context, fileName: String, content: String): String? {
        return try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/XY Music",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = context.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: return null
            try {
                context.contentResolver.openOutputStream(uri)?.use {
                    it.write(content.toByteArray(Charsets.UTF_8))
                } ?: return null
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                context.contentResolver.update(uri, values, null, null)
            } catch (error: Exception) {
                try {
                    context.contentResolver.delete(uri, null, null)
                } catch (_: Exception) {}
                return null
            }
            "Download/XY Music/$fileName"
        } catch (_: Throwable) {
            null
        }
    }
}
