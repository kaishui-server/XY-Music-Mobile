package com.xymusic.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel
import kotlin.concurrent.thread

object SystemAudioCaptureBridge {
    @Volatile
    var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun emit(bytes: ByteArray) {
        mainHandler.post { eventSink?.success(bytes) }
    }

    fun emitError(message: String) {
        mainHandler.post { eventSink?.error("CAPTURE_FAILED", message, null) }
    }
}

class SystemAudioCaptureService : Service() {
    companion object {
        const val ACTION_START = "com.xymusic.mobile.action.START_SYSTEM_AUDIO"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val NOTIFICATION_CHANNEL = "xy_music_recognition"
        private const val NOTIFICATION_ID = 4218
        private const val SAMPLE_RATE = 48000
    }

    private var projection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    @Volatile
    private var capturing = false
    private var captureThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            stopSelf()
            return START_NOT_STICKY
        }
        createNotificationChannel()
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("XY Music 正在识别系统声音")
            .setContentText("录制将在识别完成后自动停止")
            .setOngoing(true)
            .setSilent(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        try {
            startCapture(intent)
        } catch (error: Throwable) {
            SystemAudioCaptureBridge.emitError(error.message ?: "系统声音采集启动失败")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCapture(intent: Intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        stopCapture()
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        val resultData = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
            ?: throw IllegalStateException("缺少系统声音授权数据")
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mediaProjection = manager.getMediaProjection(resultCode, resultData)
            ?: throw IllegalStateException("无法创建系统声音采集会话")
        mediaProjection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopCapture()
                stopSelf()
            }
        }, Handler(Looper.getMainLooper()))
        projection = mediaProjection

        val playbackConfig = android.media.AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val recorder = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minBuffer * 4, SAMPLE_RATE * 2))
            .setAudioPlaybackCaptureConfig(playbackConfig)
            .build()
        recorder.startRecording()
        audioRecord = recorder
        capturing = true
        captureThread = thread(name = "xy-system-audio-capture", isDaemon = true) {
            val buffer = ByteArray(maxOf(minBuffer, 4096))
            while (capturing) {
                val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (read > 0) {
                    SystemAudioCaptureBridge.emit(buffer.copyOf(read))
                } else if (read < 0 && capturing) {
                    SystemAudioCaptureBridge.emitError("系统声音读取失败：$read")
                    break
                }
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "听歌识曲",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun stopCapture() {
        capturing = false
        try {
            audioRecord?.stop()
        } catch (_: Throwable) {
        }
        audioRecord?.release()
        audioRecord = null
        captureThread = null
        val activeProjection = projection
        projection = null
        activeProjection?.stop()
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }
}
