package com.ryanheise.audioservice;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.support.v4.media.MediaBrowserCompat;
import android.support.v4.media.MediaDescriptionCompat;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.RatingCompat;
import android.support.v4.media.session.MediaControllerCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import android.util.Log;
import android.util.LruCache;
import android.util.Size;
import android.view.KeyEvent;

import androidx.annotation.RequiresApi;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;
import androidx.core.app.NotificationCompat;
import androidx.media.MediaBrowserServiceCompat;
import androidx.media.VolumeProviderCompat;
import androidx.media.app.NotificationCompat.MediaStyle;
import androidx.media.utils.MediaConstants;

import java.io.FileDescriptor;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;

public class AudioService extends MediaBrowserServiceCompat {
    public static final String CONTENT_STYLE_SUPPORTED = "android.media.browse.CONTENT_STYLE_SUPPORTED";
    public static final String CONTENT_STYLE_PLAYABLE_HINT = "android.media.browse.CONTENT_STYLE_PLAYABLE_HINT";
    public static final String CONTENT_STYLE_BROWSABLE_HINT = "android.media.browse.CONTENT_STYLE_BROWSABLE_HINT";
    public static final int CONTENT_STYLE_LIST_ITEM_HINT_VALUE = 1;
    public static final int CONTENT_STYLE_GRID_ITEM_HINT_VALUE = 2;
    public static final int CONTENT_STYLE_CATEGORY_LIST_ITEM_HINT_VALUE = 3;
    public static final int CONTENT_STYLE_CATEGORY_GRID_ITEM_HINT_VALUE = 4;

    private static final String SHARED_PREFERENCES_NAME = "audio_service_preferences";

    private static final int NOTIFICATION_ID = 1124;
    private static final int REQUEST_CONTENT_INTENT = 1000;
    public static final String NOTIFICATION_CLICK_ACTION = "com.ryanheise.audioservice.NOTIFICATION_CLICK";
    public static final String CUSTOM_ACTION_STOP = "com.ryanheise.audioservice.action.STOP";
    public static final String CUSTOM_ACTION_FAST_FORWARD = "com.ryanheise.audioservice.action.FAST_FORWARD";
    public static final String CUSTOM_ACTION_REWIND = "com.ryanheise.audioservice.action.REWIND";
    private static final String BROWSABLE_ROOT_ID = "root";
    private static final String RECENT_ROOT_ID = "recent";
    // See the comment in onMediaButtonEvent to understand how the BYPASS keycodes work.
    // We hijack KEYCODE_MUTE and KEYCODE_MEDIA_RECORD since the media session subsystem
    // considers these keycodes relevant to media playback and will pass them on to us.
    public static final int KEYCODE_BYPASS_PLAY = KeyEvent.KEYCODE_MUTE;
    public static final int KEYCODE_BYPASS_PAUSE = KeyEvent.KEYCODE_MEDIA_RECORD;
    public static final int MAX_COMPACT_ACTIONS = 3;
    private static final long AUTO_ENABLED_ACTIONS = PlaybackStateCompat.ACTION_PAUSE
            | PlaybackStateCompat.ACTION_PLAY
            | PlaybackStateCompat.ACTION_REWIND
            // Auto-enabling these is bad for Android Auto since it forces the
            // previous/next buttons to always show.
            //| PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
            //| PlaybackStateCompat.ACTION_SKIP_TO_NEXT
            | PlaybackStateCompat.ACTION_FAST_FORWARD
            | PlaybackStateCompat.ACTION_SET_RATING
            // "seek" is the exception because it's the only action that
            // affects the appearance of the media notification, so we leave it
            // up to the plugin user whether to enable it (via systemActions).
            //| PlaybackStateCompat.ACTION_SEEK_TO
            | PlaybackStateCompat.ACTION_PLAY_PAUSE
            | PlaybackStateCompat.ACTION_PLAY_FROM_MEDIA_ID
            | PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH
            | PlaybackStateCompat.ACTION_SKIP_TO_QUEUE_ITEM
            | PlaybackStateCompat.ACTION_PLAY_FROM_URI
            | PlaybackStateCompat.ACTION_PREPARE
            | PlaybackStateCompat.ACTION_PREPARE_FROM_MEDIA_ID
            | PlaybackStateCompat.ACTION_PREPARE_FROM_SEARCH
            | PlaybackStateCompat.ACTION_PREPARE_FROM_URI
            | PlaybackStateCompat.ACTION_SET_REPEAT_MODE
            | PlaybackStateCompat.ACTION_SET_SHUFFLE_MODE
            | PlaybackStateCompat.ACTION_SET_CAPTIONING_ENABLED;

    static AudioService instance;
    private static PendingIntent contentIntent;
    private static ServiceListener listener;
    private static List<MediaSessionCompat.QueueItem> queue = new ArrayList<>();
    private static final Map<String, MediaMetadataCompat> mediaMetadataCache = new HashMap<>();

    public static void init(ServiceListener listener) {
        AudioService.listener = listener;
    }

    public static int toKeyCode(long action) {
        if (action == PlaybackStateCompat.ACTION_PLAY) {
            return KEYCODE_BYPASS_PLAY;
        } else if (action == PlaybackStateCompat.ACTION_PAUSE) {
            return KEYCODE_BYPASS_PAUSE;
        } else {
            return PlaybackStateCompat.toKeyCode(action);
        }
    }

    MediaMetadataCompat createMediaMetadata(String mediaId, String title, String album, String artist, String genre, Long duration, String artUri, Boolean playable, String displayTitle, String displaySubtitle, String displayDescription, RatingCompat rating, Map<?, ?> extras) {
        MediaMetadataCompat.Builder builder = new MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, mediaId)
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title);
        if (album != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album);
        if (artist != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist);
        if (genre != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_GENRE, genre);
        if (duration != null)
            builder.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration);
        if (artUri != null) {
            builder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI, artUri);
        }
        if (playable != null)
            builder.putLong("playable_long", playable ? 1 : 0);
        if (displayTitle != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, displayTitle);
        if (displaySubtitle != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, displaySubtitle);
        if (displayDescription != null)
            builder.putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_DESCRIPTION, displayDescription);
        if (rating != null) {
            builder.putRating(MediaMetadataCompat.METADATA_KEY_RATING, rating);
        }
        if (extras != null) {
            for (Object o : extras.keySet()) {
                String key = (String)o;
                Object value = extras.get(key);
                if (value instanceof Long) {
                    builder.putLong(key, (Long)value);
                } else if (value instanceof Integer) {
                    builder.putLong(key, (long)((Integer)value));
                } else if (value instanceof String) {
                    builder.putString(key, (String)value);
                } else if (value instanceof Boolean) {
                    builder.putLong(key, (Boolean)value ? 1 : 0);
                } else if (value instanceof Double) {
                    builder.putString(key, value.toString());
                }
            }
        }
        MediaMetadataCompat mediaMetadata = builder.build();
        mediaMetadataCache.put(mediaId, mediaMetadata);
        return mediaMetadata;
    }

    static MediaMetadataCompat getMediaMetadata(String mediaId) {
        return mediaMetadataCache.get(mediaId);
    }

    Bitmap loadArtBitmap(String artUriString, String loadThumbnailUri) {
        Bitmap bitmap = artBitmapCache.get(artUriString);
        if (bitmap != null) return bitmap;
        try {
            // There are 3 cases handled by this function:
            //   1. content URI with openFileDescriptor
            //   2. content URI with loadThumbnail (when Android >= Q and specified by the config)
            //   3. not content URI - loading from the file, or cache file created by the Dart side
            Uri artUri = Uri.parse(artUriString);
            boolean usesContentScheme = "content".equals(artUri.getScheme());
            FileDescriptor fileDescriptor = null;
            if (usesContentScheme) {
                try {
                    if (loadThumbnailUri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        Size defaultSize = new Size(192, 192);
                        bitmap = getContentResolver().loadThumbnail(
                                artUri,
                                new Size(config.artDownscaleWidth == -1
                                                ? defaultSize.getWidth()
                                                : config.artDownscaleWidth,
                                        config.artDownscaleHeight == -1
                                                ? defaultSize.getHeight()
                                                : config.artDownscaleHeight),
                                null);
                        if (bitmap == null) {
                            return null;
                        }
                    } else {
                        ParcelFileDescriptor parcelFileDescriptor = getContentResolver().openFileDescriptor(artUri, "r");
                        if (parcelFileDescriptor != null) {
                            fileDescriptor = parcelFileDescriptor.getFileDescriptor();
                        } else {
                            return null;
                        }
                    }
                } catch (FileNotFoundException ex) {
                    return null;
                } catch (IOException ex) {
                    return null;
                }
            }
            // Decode the image ourselves for scenarios 1 and 3 (see the comment above).
            if (!usesContentScheme || fileDescriptor != null) {
                if (config.artDownscaleWidth != -1) {
                    BitmapFactory.Options options = new BitmapFactory.Options();
                    options.inJustDecodeBounds = true;
                    if (fileDescriptor != null) {
                        BitmapFactory.decodeFileDescriptor(fileDescriptor, null, options);
                    } else {
                        BitmapFactory.decodeFile(artUri.getPath(), options);
                    }
                    options.inSampleSize = calculateInSampleSize(options, config.artDownscaleWidth, config.artDownscaleHeight);
                    options.inJustDecodeBounds = false;

                    if (fileDescriptor != null) {
                        bitmap = BitmapFactory.decodeFileDescriptor(fileDescriptor, null, options);
                    } else {
                        bitmap = BitmapFactory.decodeFile(artUri.getPath(), options);
                    }
                } else {
                    if (fileDescriptor != null) {
                        bitmap = BitmapFactory.decodeFileDescriptor(fileDescriptor);
                    } else {
                        bitmap = BitmapFactory.decodeFile(artUri.getPath());
                    }
                }
            }
            artBitmapCache.put(artUriString, bitmap);
            return bitmap;
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }

    private static int calculateInSampleSize(BitmapFactory.Options options, int reqWidth, int reqHeight) {
        final int height = options.outHeight;
        final int width = options.outWidth;
        int inSampleSize = 1;

        if (height > reqHeight || width > reqWidth) {
            final int halfHeight = height / 2;
            final int halfWidth = width / 2;
            while ((halfHeight / inSampleSize) >= reqHeight
                    && (halfWidth / inSampleSize) >= reqWidth) {
                inSampleSize *= 2;
            }
        }

        return inSampleSize;
    }

    private FlutterEngine flutterEngine;
    private AudioServiceConfig config;
    private PowerManager.WakeLock wakeLock;
    private MediaSessionCompat mediaSession;
    private MediaSessionCallback mediaSessionCallback;
    private List<MediaControl> controls = new ArrayList<>();
    private List<NotificationCompat.Action> nativeActions = new ArrayList<>();
    private List<PlaybackStateCompat.CustomAction> customActions = new ArrayList<>();
    private int[] compactActionIndices;
    // XY Music 本地补丁：媒体通知第二行（歌手位）的动态叠加歌词行。
    // NotificationLyricsManager 在歌词行滚动时写入；null/空 时不叠加，
    // 第二行保持纯歌手（蓝牙歌词开关关闭时的显示形态）。
    private static volatile String mediaSecondLine;
    // 进入歌词模式前的原始歌手行（MediaMetadata DISPLAY_SUBTITLE），
    // 关闭蓝牙歌词 / 歌词消失时恢复；切歌时由 setMetadata 重新记录。
    private static volatile String originalDisplaySubtitle;
    // 进入歌词模式前的原始 ARTIST（MediaMetadata METADATA_KEY_ARTIST）。
    // 华为/澎湃等 ROM 的系统媒体卡片第三行歌手位直接读 ARTIST 字段渲染
    // （不走 DISPLAY_SUBTITLE / contentText），歌词模式必须把 ARTIST 同步
    // 覆盖为歌词行，否则歌手行永远显示歌手名；关闭时还原。
    private static volatile String originalArtist;
    // 歌词行更新序号：每次写入歌词行 +1 并随通知 extras 透出，强制华为等
    // ROM 感知通知内容变化，防止同 ID 通知行文字被系统媒体卡片缓存。
    private static volatile int mediaSecondLineSeq;
    private MediaMetadataCompat mediaMetadata;
    private Bitmap artBitmap;
    private String notificationChannelId;
    private LruCache<String, Bitmap> artBitmapCache;
    private boolean playing = false;
    private AudioProcessingState processingState = AudioProcessingState.idle;
    private int repeatMode;
    private int shuffleMode;
    private boolean notificationCreated;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private VolumeProviderCompat volumeProvider;

    public AudioProcessingState getProcessingState() {
        return processingState;
    }

    public boolean isPlaying() {
        return playing;
    }

    public int getRepeatMode() {
        return repeatMode;
    }

    public int getShuffleMode() {
        return shuffleMode;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        repeatMode = 0;
        shuffleMode = 0;
        notificationCreated = false;
        playing = false;
        processingState = AudioProcessingState.idle;
        mediaSession = new MediaSessionCompat(this, "media-session");

        configure(new AudioServiceConfig(getApplicationContext()));

        mediaSession.setFlags(MediaSessionCompat.FLAG_HANDLES_QUEUE_COMMANDS);
        PlaybackStateCompat.Builder stateBuilder = new PlaybackStateCompat.Builder()
                .setActions(AUTO_ENABLED_ACTIONS);
        mediaSession.setPlaybackState(stateBuilder.build());
        mediaSession.setCallback(mediaSessionCallback = new MediaSessionCallback());
        setSessionToken(mediaSession.getSessionToken());
        mediaSession.setQueue(queue);

        PowerManager pm = (PowerManager)getSystemService(Context.POWER_SERVICE);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, AudioService.class.getName());

        // Get max available VM memory, exceeding this amount will throw an
        // OutOfMemory exception. Stored in kilobytes as LruCache takes an
        // int in its constructor.
        final int maxMemory = (int)(Runtime.getRuntime().maxMemory() / 1024);

        // Use 1/8th of the available memory for this memory cache.
        final int cacheSize = maxMemory / 8;

        artBitmapCache = new LruCache<String, Bitmap>(cacheSize) {
            @Override
            protected int sizeOf(String key, Bitmap bitmap) {
                // The cache size will be measured in kilobytes rather than
                // number of items.
                return bitmap.getByteCount() / 1024;
            }
        };

        flutterEngine = AudioServicePlugin.getFlutterEngine(this);
        System.out.println("flutterEngine warmed up");
    }

    @Override
    public int onStartCommand(final Intent intent, int flags, int startId) {
        MediaButtonReceiver.handleIntent(mediaSession, intent);
        return START_NOT_STICKY;
    }

    public void stop() {
        deactivateMediaSession();
        stopSelf();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        if (listener != null) {
            listener.onDestroy();
            listener = null;
        }
        mediaMetadata = null;
        artBitmap = null;
        queue.clear();
        mediaMetadataCache.clear();
        controls.clear();
        artBitmapCache.evictAll();
        compactActionIndices = null;
        releaseMediaSession();
        ServiceCompat.stopForeground(this, config.androidResumeOnClick ? STOP_FOREGROUND_DETACH : STOP_FOREGROUND_REMOVE);
        // This still does not solve the Android 11 problem.
        // if (notificationCreated) {
        //     NotificationManager notificationManager = getNotificationManager();
        //     notificationManager.cancel(NOTIFICATION_ID);
        // }
        releaseWakeLock();
        instance = null;
        notificationCreated = false;
    }

    public AudioServiceConfig getConfig() {
        return config;
    }

    public void configure(AudioServiceConfig config) {
        this.config = config;
        notificationChannelId = (config.androidNotificationChannelId != null)
            ? config.androidNotificationChannelId
            : getApplication().getPackageName() + ".channel";

        Context context = getApplicationContext();
        Intent intent = new Intent((String)null);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        if (config.androidNotificationClickStartsActivity) {
            if (config.activityClassName != null) {
                intent.setComponent(new ComponentName(context, config.activityClassName));
                //Intent intent = new Intent(context, config.activityClassName);
                intent.setAction(NOTIFICATION_CLICK_ACTION);
                contentIntent = PendingIntent.getActivity(context, REQUEST_CONTENT_INTENT, intent, flags);
            } else {
                contentIntent = null;
            }
        } else {
            // XY Music 定制：单击通知不拉起 Activity（否则会把应用切到前台），
            // 改为向进程内广播单击事件，由 NotificationClickReceiver 转交 Dart
            // 的 AudioHandler，从而只弹出迷你播放器悬浮窗。
            intent.setClass(context, NotificationClickReceiver.class);
            intent.setAction(NOTIFICATION_CLICK_ACTION);
            contentIntent = PendingIntent.getBroadcast(context, REQUEST_CONTENT_INTENT, intent, flags);
        }
        if (!config.androidResumeOnClick) {
            mediaSession.setMediaButtonReceiver(null);
        }
    }

    /// XY Music 定制：contentIntent 为广播时，由 NotificationClickReceiver 调用，
    /// 把通知栏单击事件转交 Dart 的 AudioHandler（onNotificationClicked），
    /// 不启动任何 Activity。
    public static void handleNotificationClick() {
        ServiceListener current = listener;
        if (current != null) {
            current.onNotificationClicked();
        }
    }

    int getResourceId(String resource) {
        String[] parts = resource.split("/");
        String resourceType = parts[0];
        String resourceName = parts[1];
        return getResources().getIdentifier(resourceName, resourceType, getApplicationContext().getPackageName());
    }

    NotificationCompat.Action createAction(String resource, String label, long actionCode) {
        int iconId = getResourceId(resource);
        return new NotificationCompat.Action(iconId, label,
                buildMediaButtonPendingIntent(actionCode));
    }

    private boolean needCustomMediaControl(MediaControl control) {
        return control.customAction != null;
    }

    private Bundle mapToBundle(Map<?, ?> map) {
        if (map == null) {
            return null;
        }
        Bundle bundle = new Bundle();
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            String key = entry.getKey().toString();
            Object value = entry.getValue();
            if (value instanceof Integer) {
                bundle.putInt(key, (Integer)value);
            } else if (value instanceof Long) {
                bundle.putLong(key, (Long)value);
            } else {
                bundle.putString(key, value.toString());
            }
        }
        return bundle;
    }

    PlaybackStateCompat.CustomAction createCustomAction(MediaControl control) {
        int iconId = getResourceId(control.icon);
        // XY Music 本地补丁：图标解析失败（资源收缩器误删/资源名写错）
        // 时直接跳过该控件。icon=0 的 CustomAction 在华为/荣耀等 ROM 的
        // 媒体控制中心会被当作越权注入丢弃，严格实现甚至可能在渲染时
        // 抛异常导致应用被系统判为崩溃，这里从源头不注入坏控件。
        if (iconId == 0) {
            return null;
        }
        if (control.customAction != null) {
            return new PlaybackStateCompat.CustomAction.Builder(control.customAction.name, control.label, iconId)
                .setExtras(mapToBundle(control.customAction.extras))
                .build();
        } else if (Build.VERSION.SDK_INT >= 33) {
            // Android 13 changes MediaControl behavior as documented here:
            // https://developer.android.com/about/versions/13/behavior-changes-13
            // The below actions will be added to slots 1-3, if included.
            // 1 - ACTION_PLAY, ACTION_PLAY
            // 2 - ACTION_SKIP_TO_PREVIOUS
            // 3 - ACTION_SKIP_TO_NEXT
            // Custom actions will use slots 2-5 if included.
            // - ACTION_STOP
            // - ACTION_FAST_FORWARD
            // - ACTION_REWIND
            if (control.actionCode == PlaybackStateCompat.ACTION_STOP) {
                return new PlaybackStateCompat.CustomAction.Builder(CUSTOM_ACTION_STOP, control.label, iconId).build();
            } else if (control.actionCode == PlaybackStateCompat.ACTION_FAST_FORWARD) {
                return new PlaybackStateCompat.CustomAction.Builder(CUSTOM_ACTION_FAST_FORWARD, control.label, iconId).build();
            } else if (control.actionCode == PlaybackStateCompat.ACTION_REWIND) {
                return new PlaybackStateCompat.CustomAction.Builder(CUSTOM_ACTION_REWIND, control.label, iconId).build();
            }
        }
        return null;
    }

    // XY Music 本地补丁：custom 控件（收藏/播放模式）的通知 action。
    // 华为（HarmonyOS）播控中心的五元组按钮（收藏/上一首/播放暂停/
    // 下一首/循环模式）读的是通知的 Notification.Action 列表，不渲染
    // PlaybackState 的 CustomAction——只把 custom 控件放进
    // PlaybackState 时，华为永远只显示基础三键。QQ 音乐五键齐全正是
    // 因为它的五个按钮都在通知 actions 里。点击经独立广播
    // （MediaButtonReceiver.ACTION_CUSTOM_MEDIA_ACTION）路由回 Dart
    // 的 customAction 回调（toggleFavorite/cyclePlayMode）。
    NotificationCompat.Action createCustomNotificationAction(MediaControl control) {
        int iconId = getResourceId(control.icon);
        if (iconId == 0 || control.customAction == null) {
            return null;
        }
        return new NotificationCompat.Action(iconId, control.label,
                buildCustomActionPendingIntent(control.customAction.name));
    }

    PendingIntent buildCustomActionPendingIntent(String name) {
        Intent intent = new Intent(this, MediaButtonReceiver.class);
        intent.setAction(MediaButtonReceiver.ACTION_CUSTOM_MEDIA_ACTION);
        intent.putExtra(MediaButtonReceiver.EXTRA_CUSTOM_ACTION_NAME, name);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(this, name.hashCode(), intent, flags);
    }

    public void handleCustomMediaAction(String name) {
        if (name == null || name.isEmpty() || listener == null) {
            return;
        }
        try {
            listener.onCustomAction(name, null);
        } catch (Throwable t) {
            Log.w("AudioService", "handleCustomMediaAction failed: " + name, t);
        }
    }

    PendingIntent buildMediaButtonPendingIntent(long action) {
        int keyCode = toKeyCode(action);
        if (keyCode == KeyEvent.KEYCODE_UNKNOWN)
            return null;
        Intent intent = new Intent(this, MediaButtonReceiver.class);
        intent.setAction(Intent.ACTION_MEDIA_BUTTON);
        intent.putExtra(Intent.EXTRA_KEY_EVENT, new KeyEvent(KeyEvent.ACTION_DOWN, keyCode));
        int flags = 0;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(this, keyCode, intent, flags);
    }

    PendingIntent buildDeletePendingIntent() {
        Intent intent = new Intent(this, MediaButtonReceiver.class);
        intent.setAction(MediaButtonReceiver.ACTION_NOTIFICATION_DELETE);
        int flags = 0;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getBroadcast(this, 0, intent, flags);
    }

    void setState(List<MediaControl> controls, long actionBits, int[] compactActionIndices, AudioProcessingState processingState, boolean playing, long position, long bufferedPosition, float speed, long updateTime, Integer errorCode, String errorMessage, int repeatMode, int shuffleMode, boolean captioningEnabled, Long queueIndex) {
        boolean notificationChanged = false;
        if (!controls.equals(this.controls)) {
            notificationChanged = true;
        }
        this.controls = controls;
        this.nativeActions.clear();
        this.customActions.clear();
        // XY Music 本地补丁：controls 索引 → 通知标准控件索引映射。
        // custom 控件进 PlaybackState（供 Android 13+ 系统媒体卡片
        // 渲染）的同时也生成通知 action（华为播控中心五元组按钮读的
        // 是通知 actions，见 createCustomNotificationAction 注释），
        // compact 索引按统一的通知 actions 空间换算。
        final int[] controlToNative = new int[controls.size()];
        for (int i = 0; i < controls.size(); i++) {
            final MediaControl control = controls.get(i);
            final PlaybackStateCompat.CustomAction customAction = createCustomAction(control);
            if (customAction != null) {
                customActions.add(customAction);
                final NotificationCompat.Action customNotificationAction =
                        createCustomNotificationAction(control);
                if (customNotificationAction != null) {
                    controlToNative[i] = nativeActions.size();
                    nativeActions.add(customNotificationAction);
                } else {
                    controlToNative[i] = -1;
                }
            } else {
                controlToNative[i] = nativeActions.size();
                nativeActions.add(createAction(control.icon, control.label, control.actionCode));
            }
        }
        final int[] mappedCompact = mapCompactActionIndices(compactActionIndices, controlToNative);
        if (!Arrays.equals(mappedCompact, this.compactActionIndices)) {
            notificationChanged = true;
        }
        this.compactActionIndices = mappedCompact;
        boolean wasPlaying = this.playing;
        AudioProcessingState oldProcessingState = this.processingState;
        this.processingState = processingState;
        this.playing = playing;
        this.repeatMode = repeatMode;
        this.shuffleMode = shuffleMode;

        // XY Music 本地补丁：无条件置位切歌 action bits。
        // Android 13+（含澎湃 HyperOS）系统媒体通知的按钮槽位完全由
        // PlaybackState 的 actions 决定：slot2 上一首、slot3 下一首
        // （缺失时该槽位回退给 CustomAction 或留空）。宿主 Dart 侧的
        // _MediaSessionBridge 负责补齐切歌控件，但存在安装时序/播放器
        // 重建导致补丁丢失的场景（实测澎湃系统上只显示「桌面歌词+暂停」
        // 两个按钮），这里在原生层兜底保证 slot2/slot3 恒为切歌键。
        // 本应用自身维护播放队列，上一首/下一首始终有效，且点击事件
        // 经媒体会话回调（onSkipToPrevious/onSkipToNext）路由回宿主。
        actionBits |= PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                | PlaybackStateCompat.ACTION_SKIP_TO_NEXT;

        PlaybackStateCompat.Builder stateBuilder = new PlaybackStateCompat.Builder()
                .setActions(AUTO_ENABLED_ACTIONS | actionBits)
                .setState(getPlaybackState(), position, speed, updateTime)
                .setBufferedPosition(bufferedPosition);

        for (PlaybackStateCompat.CustomAction action : this.customActions) {
            // XY Music 本地补丁：华为等 ROM 对媒体会话自定义控件有安全
            // 审查（越权判定），单个控件注入异常不应拖垮整个播放状态
            // 发布，否则通知/媒体卡片全灭且进程被记为崩溃。
            try {
                stateBuilder.addCustomAction(action);
            } catch (Throwable t) {
                Log.w("AudioService", "addCustomAction failed: " + action.getAction(), t);
            }
        }

        if (queueIndex != null)
            stateBuilder.setActiveQueueItemId(queueIndex);
        if (errorCode != null && errorMessage != null)
            stateBuilder.setErrorMessage(errorCode, errorMessage);
        else if (errorMessage != null)
            stateBuilder.setErrorMessage(-987654, errorMessage);

        if (mediaMetadata != null) {
            // Update the progress bar in the browse view as content is playing as explained
            // here: https://developer.android.com/training/cars/media#browse-progress-bar
            Bundle extras = new Bundle();
            extras.putString(MediaConstants.PLAYBACK_STATE_EXTRAS_KEY_MEDIA_ID, mediaMetadata.getDescription().getMediaId());
            stateBuilder.setExtras(extras);
        }

        mediaSession.setPlaybackState(stateBuilder.build());
        mediaSession.setRepeatMode(repeatMode);
        mediaSession.setShuffleMode(shuffleMode);
        mediaSession.setCaptioningEnabled(captioningEnabled);

        if (!wasPlaying && playing) {
            enterPlayingState();
        } else if (wasPlaying && !playing) {
            exitPlayingState();
        }

        if (oldProcessingState != AudioProcessingState.idle && processingState == AudioProcessingState.idle) {
            // TODO: Handle completed state as well?
            stop();
        } else if (processingState != AudioProcessingState.idle && notificationChanged) {
            updateNotification();
        }
    }

    public void setPlaybackInfo(int playbackType, Integer volumeControlType, Integer maxVolume, Integer volume) {
        if (playbackType == MediaControllerCompat.PlaybackInfo.PLAYBACK_TYPE_LOCAL) {
            // We have to wait 'til media2 before we can use AudioAttributes.
            mediaSession.setPlaybackToLocal(AudioManager.STREAM_MUSIC);
            volumeProvider = null;
        } else if (playbackType == MediaControllerCompat.PlaybackInfo.PLAYBACK_TYPE_REMOTE) {
            if (volumeProvider == null || volumeControlType != volumeProvider.getVolumeControl() || maxVolume != volumeProvider.getMaxVolume()) {
                volumeProvider = new VolumeProviderCompat(volumeControlType, maxVolume, volume) {
                    @Override
                    public void onSetVolumeTo(int volumeIndex) {
                        if (listener == null) return;
                        listener.onSetVolumeTo(volumeIndex);
                    }
                    @Override
                    public void onAdjustVolume(int direction) {
                        if (listener == null) return;
                        listener.onAdjustVolume(direction);
                    }
                };
            } else {
                volumeProvider.setCurrentVolume(volume);
            }
            mediaSession.setPlaybackToRemote(volumeProvider);
        } else {
            // silently ignore
        }
    }

    public int getPlaybackState() {
        switch (processingState) {
        case idle: return PlaybackStateCompat.STATE_NONE;
        case loading: return PlaybackStateCompat.STATE_CONNECTING;
        case buffering: return PlaybackStateCompat.STATE_BUFFERING;
        case ready: return playing ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED;
        case completed: return playing ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED;
        case error: return PlaybackStateCompat.STATE_ERROR;
        default: return PlaybackStateCompat.STATE_NONE;
        }
    }

    /**
     * XY Music 本地补丁：把 controls 空间的 compact 索引映射到通知标准
     * 控件空间。宿主桥接发出 [收藏, 上一首, 播放/暂停, 下一首, 播放模式]，
     * custom 控件不进 Android 12 传统通知的 actions，不映射的话
     * setShowActionsInCompactView(3) 会越界（华为 Android 12 实测
     * post 通知时 IndexOutOfBoundsException: Index: 3, Size: 3 闪退）。
     * 越界、重复或指向 custom 控件的索引被丢弃，映射结果为空时返回
     * null（buildNotification 走默认前 3 个标准控件）。
     */
    private int[] mapCompactActionIndices(int[] compactActionIndices, int[] controlToNative) {
        if (compactActionIndices == null) return null;
        final int[] mapped = new int[Math.min(MAX_COMPACT_ACTIONS, compactActionIndices.length)];
        int count = 0;
        for (int raw : compactActionIndices) {
            if (count >= mapped.length) break;
            if (raw < 0 || raw >= controlToNative.length) continue;
            final int nativeIndex = controlToNative[raw];
            if (nativeIndex < 0) continue;
            boolean duplicate = false;
            for (int i = 0; i < count; i++) {
                if (mapped[i] == nativeIndex) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            mapped[count++] = nativeIndex;
        }
        return count == 0 ? null : Arrays.copyOf(mapped, count);
    }

    private Notification buildNotification() {
        int[] compactActionIndices = this.compactActionIndices;
        if (compactActionIndices == null) {
            compactActionIndices = new int[Math.min(MAX_COMPACT_ACTIONS, nativeActions.size())];
            for (int i = 0; i < compactActionIndices.length; i++) compactActionIndices[i] = i;
        }
        NotificationCompat.Builder builder = getNotificationBuilder();
        if (mediaMetadata != null) {
            MediaDescriptionCompat description = mediaMetadata.getDescription();
            if (description.getTitle() != null)
                builder.setContentTitle(description.getTitle());
            if (description.getSubtitle() != null) {
                // XY Music 本地补丁：蓝牙歌词开启时歌手位直接显示当前歌词行
                // （逐行歌词取代歌手名，即媒体卡片三行布局之二）；关闭时
                // mediaSecondLine 为 null，恢复纯歌手名。
                String subtitle = description.getSubtitle().toString();
                String lyric = mediaSecondLine;
                if (lyric != null && !lyric.isEmpty()) {
                    builder.setContentText(lyric);
                } else {
                    builder.setContentText(subtitle);
                }
            }
            if (description.getDescription() != null)
                builder.setSubText(description.getDescription());
            synchronized (this) {
                if (artBitmap != null)
                    builder.setLargeIcon(artBitmap);
            }
        }
        if (config.androidNotificationClickStartsActivity)
            builder.setContentIntent(mediaSession.getController().getSessionActivity());
        else if (contentIntent != null)
            // XY Music 定制：clickStartsActivity 关闭时仍挂上广播 PendingIntent，
            // 保证单击通知（以及快捷设置里的媒体卡片）能触发悬浮窗。
            builder.setContentIntent(contentIntent);
        // TODO: Look at setColorized
        if (config.notificationColor != -1)
            builder.setColor(config.notificationColor);
        for (NotificationCompat.Action action : nativeActions) {
            builder.addAction(action);
        }
        final MediaStyle style = new MediaStyle()
            .setMediaSession(mediaSession.getSessionToken());
        // XY Music 本地补丁：恒调用 setShowActionsInCompactView。
        // 上游按官方建议在 Android 13+ 跳过该方法（系统媒体卡片按
        // PlaybackState 自动分配按钮槽位），但鸿蒙/HarmonyOS 兼容层在
        // SDK>=33 时仍按该方法决定折叠态按钮行，跳过会导致媒体卡片
        // 只剩播放/暂停默认槽（实测：缺上一曲/下一曲/循环按钮）。
        // LX-X 等同类播放器正是恒调用该方法才三键齐全。原生 Android
        // 13+ 上该调用无副作用（系统仍按 PlaybackState 渲染槽位），
        // try/catch 兜底防止个别 ROM 实现抛异常导致通知构建失败。
        try {
            style.setShowActionsInCompactView(compactActionIndices);
        } catch (Throwable ignored) {
            // ROM 实现差异：忽略，按钮行由系统默认策略兜底。
        }
        if (config.androidNotificationOngoing) {
            style.setShowCancelButton(true);
            style.setCancelButtonIntent(buildMediaButtonPendingIntent(PlaybackStateCompat.ACTION_STOP));
            builder.setOngoing(true);
        }
        builder.setStyle(style);
        // XY Music 本地补丁：通知 extras 附带歌词行递增序号。同 ID 通知在
        // 华为/澎湃等 ROM 上存在文字缓存（buildNotification 内容变了但卡片
        // 不刷新），序号变化可强制系统感知「内容已更新」。
        try {
            Bundle xyExtras = new Bundle(builder.getExtras());
            xyExtras.putInt("xy_lyric_seq", mediaSecondLineSeq);
            builder.setExtras(xyExtras);
        } catch (Throwable ignored) {
            // extras 失败只丢一次哨兵，不影响通知主体。
        }
        return builder.build();
    }

    private NotificationManager getNotificationManager() {
        return (NotificationManager)getSystemService(Context.NOTIFICATION_SERVICE);
    }

    private /*synchronized*/ NotificationCompat.Builder getNotificationBuilder() {
        // This local variable could be commented out and replaced by an
        // instance variable if we want to reuse the builder instance. However,
        // there doesn't turn out to be much benefit to this since we don't
        // actually reuse any of the previous notification values when setting
        // a new notification.
        NotificationCompat.Builder notificationBuilder = null;
        if (notificationBuilder == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                createChannel();
            notificationBuilder = new NotificationCompat.Builder(this, notificationChannelId)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .setShowWhen(false)
                    .setDeleteIntent(buildDeletePendingIntent())
            ;
        }
        int iconId = getResourceId(config.androidNotificationIcon);
        notificationBuilder.setSmallIcon(iconId);
        return notificationBuilder;
    }

    public void handleDeleteNotification() {
        if (listener == null) return;
        listener.onClose();
    }


    @RequiresApi(Build.VERSION_CODES.O)
    private void createChannel() {
        NotificationManager notificationManager = getNotificationManager();
        NotificationChannel channel = notificationManager.getNotificationChannel(notificationChannelId);
        if (channel == null) {
            channel = new NotificationChannel(notificationChannelId, config.androidNotificationChannelName, NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(config.androidShowNotificationBadge);
            if (config.androidNotificationChannelDescription != null)
                channel.setDescription(config.androidNotificationChannelDescription);
            notificationManager.createNotificationChannel(channel);
        }
    }

    private void updateNotification() {
        if (notificationCreated) {
            getNotificationManager().notify(NOTIFICATION_ID, buildNotification());
        }
    }

    /**
     * XY Music 本地补丁：更新媒体通知第二行（歌手位）的叠加歌词行。
     * 由 NotificationLyricsManager 在歌词行滚动时调用；传 null/空 清除
     * 叠加（第二行恢复为纯歌手）。全链路 try/catch，防华为越权闪退。
     *
     * 除通知 contentText 外同步刷新 MediaSession 的 MediaMetadata
     * DISPLAY_SUBTITLE：华为/澎湃等 ROM 的系统媒体卡片优先读取
     * MediaMetadata（标题/副标题/描述）而非通知 contentText，只改通知
     * 文本会被系统卡片缓存住旧内容。两者同源更新，保证两种数据源下
     * 第三行都能显示滚动歌词；通知 extras 附带递增序号强制系统感知变化。
     */
    public static void setMediaSecondLine(String lyric) {
        mediaSecondLine = (lyric == null || lyric.isEmpty()) ? null : lyric;
        try {
            AudioService service = instance;
            if (service != null) {
                service.applyMediaSecondLine();
                if (service.notificationCreated) {
                    service.updateNotification();
                }
            }
        } catch (Throwable ignored) {
            // 通知更新失败不影响播放进程。
        }
    }

    /** 同步 MediaMetadata 的 DISPLAY_SUBTITLE / ARTIST（媒体卡片第三行数据源）。 */
    private void applyMediaSecondLine() {
        mediaSecondLineSeq++;
        if (mediaMetadata == null) return;
        if (mediaSecondLine != null && !mediaSecondLine.isEmpty()) {
            // 首次进入歌词模式时记录原始歌手名，供关闭时恢复。
            if (originalDisplaySubtitle == null) {
                MediaDescriptionCompat d = mediaMetadata.getDescription();
                originalDisplaySubtitle =
                    d.getSubtitle() != null ? d.getSubtitle().toString() : null;
            }
            if (originalArtist == null) {
                CharSequence artist =
                    mediaMetadata.getText(MediaMetadataCompat.METADATA_KEY_ARTIST);
                originalArtist = artist != null ? artist.toString() : null;
            }
            if (originalDisplaySubtitle == null ||
                !originalDisplaySubtitle.equals(mediaSecondLine)) {
                mediaMetadata = new MediaMetadataCompat.Builder(mediaMetadata)
                    .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, mediaSecondLine)
                    .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, mediaSecondLine)
                    .build();
                mediaSession.setMetadata(mediaMetadata);
            }
        } else {
            MediaMetadataCompat.Builder builder = null;
            if (originalDisplaySubtitle != null) {
                builder = new MediaMetadataCompat.Builder(mediaMetadata)
                    .putString(
                        MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE,
                        originalDisplaySubtitle
                    );
            }
            if (originalArtist != null) {
                if (builder == null) builder = new MediaMetadataCompat.Builder(mediaMetadata);
                builder.putString(
                    MediaMetadataCompat.METADATA_KEY_ARTIST,
                    originalArtist
                );
            }
            if (builder != null) {
                mediaMetadata = builder.build();
                mediaSession.setMetadata(mediaMetadata);
            }
            originalDisplaySubtitle = null;
            originalArtist = null;
        }
    }

    private void enterPlayingState() {
        ContextCompat.startForegroundService(this, new Intent(AudioService.this, AudioService.class));
        if (!mediaSession.isActive())
            mediaSession.setActive(true);

        acquireWakeLock();
        mediaSession.setSessionActivity(contentIntent);
        internalStartForeground();
    }

    private void exitPlayingState() {
        if (config.androidStopForegroundOnPause) {
            exitForegroundState();
        }
    }

    private void exitForegroundState() {
        ServiceCompat.stopForeground(this, STOP_FOREGROUND_DETACH);
        releaseWakeLock();
    }

    private void internalStartForeground() {
        startForeground(NOTIFICATION_ID, buildNotification());
        notificationCreated = true;
    }

    private void acquireWakeLock() {
        if (!wakeLock.isHeld())
            wakeLock.acquire();
    }

    private void releaseWakeLock() {
        if (wakeLock.isHeld())
            wakeLock.release();
    }

    private void activateMediaSession() {
        if (!mediaSession.isActive())
            mediaSession.setActive(true);
    }

    private void deactivateMediaSession() {
        if (mediaSession.isActive()) {
            mediaSession.setActive(false);
        }
        // Force cancellation of the notification
        getNotificationManager().cancel(NOTIFICATION_ID);
    }

    private void releaseMediaSession() {
        if (mediaSession == null) return;
        deactivateMediaSession();
        mediaSession.release();
        mediaSession = null;
    }

    /**
     * Updates queue.
     * Gets called from background thread.
     */
    synchronized void setQueue(List<MediaSessionCompat.QueueItem> queue) {
        AudioService.queue = queue;
        mediaSession.setQueue(queue);
    }

    void playMediaItem(MediaDescriptionCompat description) {
        mediaSessionCallback.onPlayMediaItem(description);
    }

    /**
     * Updates metadata, loads the art and updates the notification.
     * Gets called from background thread.
     * <p>
     * Also adds the loaded art bitmap to the MediaMetadata.
     * This is needed to display art in lock screen in versions
     * prior Android 11, in which this feature was removed.
     * <p>
     * See:
     *  - https://developer.android.com/guide/topics/media-apps/working-with-a-media-session#album_artwork
     *  - https://9to5google.com/2020/08/02/android-11-lockscreen-art/
     */
    synchronized void setMetadata(MediaMetadataCompat mediaMetadata) {
        String artCacheFilePath = mediaMetadata.getString("artCacheFile");
        if (artCacheFilePath != null) {
            // Load local files and network images, cached in files
            artBitmap = loadArtBitmap(artCacheFilePath, null);
            mediaMetadata = putArtToMetadata(mediaMetadata);
        } else {
            // Load content:// URIs
            String artUri = mediaMetadata.getString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI);
            if (artUri != null && artUri.startsWith("content:")) {
                String loadThumbnailUri = mediaMetadata.getString("loadThumbnailUri");
                artBitmap = loadArtBitmap(artUri, loadThumbnailUri);
                mediaMetadata = putArtToMetadata(mediaMetadata);
            } else {
                artBitmap = null;
            }
        }
        this.mediaMetadata = mediaMetadata;
        // XY Music 本地补丁：蓝牙歌词开启（mediaSecondLine 非空）时，新歌
        // 元数据到达后立即记录原始歌手名并把 DISPLAY_SUBTITLE / ARTIST 覆盖
        // 为当前歌词行，保证切歌后华为等 ROM 的媒体卡片第三行继续显示歌词。
        if (mediaSecondLine != null && !mediaSecondLine.isEmpty()) {
            MediaDescriptionCompat d = mediaMetadata.getDescription();
            originalDisplaySubtitle =
                d.getSubtitle() != null ? d.getSubtitle().toString() : null;
            CharSequence artist =
                mediaMetadata.getText(MediaMetadataCompat.METADATA_KEY_ARTIST);
            originalArtist = artist != null ? artist.toString() : null;
            mediaMetadata = new MediaMetadataCompat.Builder(mediaMetadata)
                .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, mediaSecondLine)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, mediaSecondLine)
                .build();
        } else {
            originalDisplaySubtitle = null;
            originalArtist = null;
        }
        mediaSession.setMetadata(mediaMetadata);
        handler.removeCallbacksAndMessages(null);
        handler.post(this::updateNotification);
    }

    private MediaMetadataCompat putArtToMetadata(MediaMetadataCompat mediaMetadata) {
        return new MediaMetadataCompat.Builder(mediaMetadata)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artBitmap)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, artBitmap)
                .build();
    }

    @Override
    public BrowserRoot onGetRoot(String clientPackageName, int clientUid, Bundle rootHints) {
        Boolean isRecentRequest = rootHints == null ? null : (Boolean)rootHints.getBoolean(BrowserRoot.EXTRA_RECENT);
        if (isRecentRequest == null) isRecentRequest = false;
        Bundle extras = config.getBrowsableRootExtras();
        return new BrowserRoot(isRecentRequest ? RECENT_ROOT_ID : BROWSABLE_ROOT_ID, extras);
        // The response must be given synchronously, and we can't get a
        // synchronous response from the Dart layer. For now, we hardcode
        // the root to "root". This may improve in media2.
        //return listener.onGetRoot(clientPackageName, clientUid, rootHints);
    }

    @Override
    public void onLoadChildren(final String parentMediaId, final Result<List<MediaBrowserCompat.MediaItem>> result) {
        onLoadChildren(parentMediaId, result, null);
    }

    @Override
    public void onLoadChildren(final String parentMediaId, final Result<List<MediaBrowserCompat.MediaItem>> result, Bundle options) {
        if (listener == null) {
            result.sendResult(new ArrayList<>());
            return;
        }
        listener.onLoadChildren(parentMediaId, result, options);
    }

    @Override
    public void onLoadItem(String itemId, Result<MediaBrowserCompat.MediaItem> result) {
        if (listener == null) {
            result.sendResult(null);
            return;
        }
        listener.onLoadItem(itemId, result);
    }

    @Override
    public void onSearch(String query, Bundle extras, Result<List<MediaBrowserCompat.MediaItem>> result) {
        if (listener == null) {
            result.sendResult(new ArrayList<>());
            return;
        }
        listener.onSearch(query, extras, result);
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        if (listener != null) {
            listener.onTaskRemoved();
        }
        super.onTaskRemoved(rootIntent);
    }

    public class MediaSessionCallback extends MediaSessionCompat.Callback {
        @Override
        public void onAddQueueItem(MediaDescriptionCompat description) {
            if (listener == null) return;
            listener.onAddQueueItem(getMediaMetadata(description.getMediaId()));
        }

        @Override
        public void onAddQueueItem(MediaDescriptionCompat description, int index) {
            if (listener == null) return;
            listener.onAddQueueItemAt(getMediaMetadata(description.getMediaId()), index);
        }

        @Override
        public void onRemoveQueueItem(MediaDescriptionCompat description) {
            if (listener == null) return;
            listener.onRemoveQueueItem(getMediaMetadata(description.getMediaId()));
        }

        @Override
        public void onPrepare() {
            if (listener == null) return;
            if (!mediaSession.isActive())
                mediaSession.setActive(true);
            listener.onPrepare();
        }

        @Override
        public void onPrepareFromMediaId(String mediaId, Bundle extras) {
            if (listener == null) return;
            if (!mediaSession.isActive())
                mediaSession.setActive(true);
            listener.onPrepareFromMediaId(mediaId, extras);
        }

        @Override
        public void onPrepareFromSearch(String query, Bundle extras) {
            if (listener == null) return;
            if (!mediaSession.isActive())
                mediaSession.setActive(true);
            listener.onPrepareFromSearch(query, extras);
        }

        @Override
        public void onPrepareFromUri(Uri uri, Bundle extras) {
            if (listener == null) return;
            if (!mediaSession.isActive())
                mediaSession.setActive(true);
            listener.onPrepareFromUri(uri, extras);
        }

        @Override
        public void onPlay() {
            if (listener == null) return;
            listener.onPlay();
        }

        @Override
        public void onPlayFromMediaId(final String mediaId, final Bundle extras) {
            if (listener == null) return;
            listener.onPlayFromMediaId(mediaId, extras);
        }

        @Override
        public void onPlayFromSearch(final String query, final Bundle extras) {
            if (listener == null) return;
            listener.onPlayFromSearch(query, extras);
        }

        @Override
        public void onPlayFromUri(final Uri uri, final Bundle extras) {
            if (listener == null) return;
            listener.onPlayFromUri(uri, extras);
        }

        @Override
        public boolean onMediaButtonEvent(Intent mediaButtonEvent) {
            if (listener == null) return false;
            // TODO: use typesafe version once SDK 33 is released.
            @SuppressWarnings("deprecation")
            final KeyEvent event = (KeyEvent)mediaButtonEvent.getExtras().getParcelable(Intent.EXTRA_KEY_EVENT);
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                switch (event.getKeyCode()) {
                case KEYCODE_BYPASS_PLAY:
                    onPlay();
                    break;
                case KEYCODE_BYPASS_PAUSE:
                    onPause();
                    break;
                case KeyEvent.KEYCODE_MEDIA_STOP:
                    onStop();
                    break;
                case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
                    onFastForward();
                    break;
                case KeyEvent.KEYCODE_MEDIA_REWIND:
                    onRewind();
                    break;
                // Android unfortunately reroutes media button clicks to
                // KEYCODE_MEDIA_PLAY/PAUSE instead of the expected KEYCODE_HEADSETHOOK
                // or KEYCODE_MEDIA_PLAY_PAUSE. As a result, we can't genuinely tell if
                // onMediaButtonEvent was called because a media button was actually
                // pressed or because a PLAY/PAUSE action was pressed instead! To get
                // around this, we make PLAY and PAUSE actions use different keycodes:
                // KEYCODE_BYPASS_PLAY/PAUSE. Now if we get KEYCODE_MEDIA_PLAY/PUASE
                // we know it is actually a media button press.
                case KeyEvent.KEYCODE_MEDIA_NEXT:
                case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                case KeyEvent.KEYCODE_MEDIA_PLAY:
                case KeyEvent.KEYCODE_MEDIA_PAUSE:
                    // These are the "genuine" media button click events
                case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                case KeyEvent.KEYCODE_HEADSETHOOK:
                    listener.onClick(eventToButton(event));
                    break;
                }
            }
            return true;
        }

        private MediaButton eventToButton(KeyEvent event) {
            switch (event.getKeyCode()) {
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_HEADSETHOOK:
                return MediaButton.media;
            case KeyEvent.KEYCODE_MEDIA_NEXT:
                return MediaButton.next;
            case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                return MediaButton.previous;
            default:
                return MediaButton.media;
            }
        }

        @Override
        public void onPause() {
            if (listener == null) return;
            listener.onPause();
        }

        @Override
        public void onStop() {
            if (listener == null) return;
            listener.onStop();
        }

        @Override
        public void onSkipToNext() {
            if (listener == null) return;
            listener.onSkipToNext();
        }

        @Override
        public void onSkipToPrevious() {
            if (listener == null) return;
            listener.onSkipToPrevious();
        }

        @Override
        public void onFastForward() {
            if (listener == null) return;
            listener.onFastForward();
        }

        @Override
        public void onRewind() {
            if (listener == null) return;
            listener.onRewind();
        }

        @Override
        public void onSkipToQueueItem(long id) {
            if (listener == null) return;
            listener.onSkipToQueueItem(id);
        }

        @Override
        public void onSeekTo(long pos) {
            if (listener == null) return;
            listener.onSeekTo(pos);
        }

        @Override
        public void onSetRating(RatingCompat rating) {
            if (listener == null) return;
            listener.onSetRating(rating);
        }

        @Override
        public void onSetPlaybackSpeed(float speed) {
            if (listener == null) return;
            listener.onSetPlaybackSpeed(speed);
        }

        @Override
        public void onSetCaptioningEnabled(boolean enabled) {
            if (listener == null) return;
            listener.onSetCaptioningEnabled(enabled);
        }

        @Override
        public void onSetRepeatMode(int repeatMode) {
            if (listener == null) return;
            listener.onSetRepeatMode(repeatMode);
        }

        @Override
        public void onSetShuffleMode(int shuffleMode) {
            if (listener == null) return;
            listener.onSetShuffleMode(shuffleMode);
        }

        @Override
        public void onCustomAction(String action, Bundle extras) {
            if (listener == null) return;
            if (CUSTOM_ACTION_STOP.equals(action)) {
                listener.onStop();
            } else if (CUSTOM_ACTION_FAST_FORWARD.equals(action)) {
                listener.onFastForward();
            } else if (CUSTOM_ACTION_REWIND.equals(action)) {
                listener.onRewind();
            } else {
                listener.onCustomAction(action, extras);
            }
        }

        @Override
        public void onSetRating(RatingCompat rating, Bundle extras) {
            if (listener == null) return;
            listener.onSetRating(rating, extras);
        }

        //
        // NON-STANDARD METHODS
        //

        public void onPlayMediaItem(final MediaDescriptionCompat description) {
            if (listener == null) return;
            listener.onPlayMediaItem(getMediaMetadata(description.getMediaId()));
        }
    }

    public interface ServiceListener {
        //BrowserRoot onGetRoot(String clientPackageName, int clientUid, Bundle rootHints);
        void onLoadChildren(String parentMediaId, Result<List<MediaBrowserCompat.MediaItem>> result, Bundle options);
        void onLoadItem(String itemId, Result<MediaBrowserCompat.MediaItem> result);
        void onSearch(String query, Bundle extras, Result<List<MediaBrowserCompat.MediaItem>> result);
        void onClick(MediaButton mediaButton);
        void onPrepare();
        void onPrepareFromMediaId(String mediaId, Bundle extras);
        void onPrepareFromSearch(String query, Bundle extras);
        void onPrepareFromUri(Uri uri, Bundle extras);
        void onPlay();
        void onPlayFromMediaId(String mediaId, Bundle extras);
        void onPlayFromSearch(String query, Bundle extras);
        void onPlayFromUri(Uri uri, Bundle extras);
        void onSkipToQueueItem(long id);
        void onPause();
        void onSkipToNext();
        void onSkipToPrevious();
        void onFastForward();
        void onRewind();
        void onStop();
        void onSeekTo(long pos);
        void onSetRating(RatingCompat rating);
        void onSetRating(RatingCompat rating, Bundle extras);
        void onSetRepeatMode(int repeatMode);
        void onSetShuffleMode(int shuffleMode);
        void onCustomAction(String action, Bundle extras);
        void onAddQueueItem(MediaMetadataCompat metadata);
        void onAddQueueItemAt(MediaMetadataCompat metadata, int index);
        void onRemoveQueueItem(MediaMetadataCompat metadata);
        void onRemoveQueueItemAt(int index);
        void onSetPlaybackSpeed(float speed);
        void onSetCaptioningEnabled(boolean enabled);
        void onSetVolumeTo(int volumeIndex);
        void onAdjustVolume(int direction);

        //
        // NON-STANDARD METHODS
        //

        void onPlayMediaItem(MediaMetadataCompat metadata);
        void onTaskRemoved();
        void onClose();
        void onDestroy();
        void onNotificationClicked();
    }
}
