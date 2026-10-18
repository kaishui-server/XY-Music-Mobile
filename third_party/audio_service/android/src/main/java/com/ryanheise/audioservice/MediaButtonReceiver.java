package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";

    // XY Music 本地补丁：custom 控件（收藏/播放模式）的通知 action
    // 点击广播。标准媒体键走 ACTION_MEDIA_BUTTON + keycode，custom
    // 控件没有对应 keycode，用独立广播 action 携带 customAction 名字
    // 路由回 AudioService → Dart 的 customAction 回调。
    public static final String ACTION_CUSTOM_MEDIA_ACTION = "com.ryanheise.audioservice.intent.action.CUSTOM_MEDIA_ACTION";
    public static final String EXTRA_CUSTOM_ACTION_NAME = "com.ryanheise.audioservice.extra.CUSTOM_ACTION_NAME";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null && AudioService.instance != null) {
            if (ACTION_NOTIFICATION_DELETE.equals(intent.getAction())) {
                AudioService.instance.handleDeleteNotification();
                return;
            }
            if (ACTION_CUSTOM_MEDIA_ACTION.equals(intent.getAction())) {
                AudioService.instance.handleCustomMediaAction(
                        intent.getStringExtra(EXTRA_CUSTOM_ACTION_NAME));
                return;
            }
        }
        super.onReceive(context, intent);
    }
}
