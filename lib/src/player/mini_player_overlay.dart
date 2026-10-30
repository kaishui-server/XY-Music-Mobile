import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../rust/api.dart';
import '../widgets/cover_image.dart';
import 'player_provider.dart';

/// Android 迷你播放器悬浮窗桥接（替代画中画）。
///
/// 悬浮窗是系统级独立窗口（`TYPE_APPLICATION_OVERLAY`），窗口内的封面、
/// 标题、可拖动进度条与五个按钮（播放模式/上一首/播放暂停/下一首/播放列表）
/// 全部由原生 View 承载，因此天然可点击——这一点与画中画（系统禁止与应用
/// 界面互动）有本质区别。
///
/// 数据单向：Dart 推送播放状态到原生（`update`），原生把窗口内的操作回传
/// （`onAction`/`onCloseRequested`），由播放层执行。
///
/// 注意：通知栏/灵动胶囊的点击不在此处理——点击只走进程内广播恢复播放
/// 状态展示，绝不能触发浮窗启停（否则未授权悬浮窗权限的机型会频繁跳转
/// 「显示在其他应用上层」授权页）。
class MiniPlayerOverlayBridge {
  MiniPlayerOverlayBridge._();

  static const _channel = MethodChannel('com.xymusic.mobile/mini_player');

  static WidgetRef? _ref;
  static bool _handlerInstalled = false;

  static void init(WidgetRef ref) {
    _ref = ref;
    if (!Platform.isAndroid) return;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onAction':
          _dispatchAction(call.arguments);
        case 'onCloseRequested':
          _syncSetting(false);
      }
      return null;
    });
  }

  /// 悬浮窗内的按钮/进度条操作：分发到播放层执行。
  static void _dispatchAction(Object? arguments) {
    final ref = _ref;
    if (ref == null) return;
    final map = arguments is Map ? arguments : const <Object?, Object?>{};
    final action = map['action']?.toString() ?? '';
    final value = (map['value'] as num?)?.toDouble() ?? 0;
    final player = ref.read(playerProvider.notifier);
    switch (action) {
      case 'toggle':
        unawaited(player.toggle());
      case 'previous':
        unawaited(player.previous());
      case 'next':
        unawaited(player.next());
      case 'cyclePlayMode':
        unawaited(player.cyclePlayMode());
      case 'seek':
        // 原生回传毫秒，播放层用秒。
        unawaited(player.seek(value / 1000.0));
      case 'playIndex':
        unawaited(player.playIndex(value.round()));
      case 'setAppVolume':
        // 悬浮窗音量条在「音量键调节应用内音量」开启时回传 0..1，写
        // settings.volume，由设置监听统一下发播放引擎（与音量键同路径）。
        unawaited(player.setAppVolume(value));
    }
  }

  /// 浮窗关闭按钮：把设置里的开关同步为关闭。写入设置会触发
  /// 根节点的监听，由统一的 [requestSync] 链路完成浮窗启停（单一真源）。
  static void _syncSetting(bool enabled) {
    final ref = _ref;
    if (ref == null) return;
    try {
      final current = ref.read(settingsProvider).valueOrNull;
      if (current == null || current.miniPlayerOverlayEnabled == enabled) return;
      unawaited(
        ref.read(settingsProvider.notifier).setMiniPlayerOverlayEnabled(enabled),
      );
    } catch (_) {
      // 宿主界面已销毁（ProviderScope 已释放）时忽略。
    }
  }

  // ---------------------------------------------------------------- 同步状态
  static bool? _lastEnabled;
  static bool _hiddenSent = false;
  static bool _syncInFlight = false;
  static bool _syncPending = false;
  static Timer? _syncTimer;
  static DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);

  static String? _lastSignature;
  static bool? _lastIsPlaying;
  static int _lastSentPositionMs = -1000000;
  static DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  static int _syncGeneration = 0;

  static List<QueueItem>? _queueList;
  static String _queueJson = '';
  static int _queueRevision = 0;

  static String? _coverKey;
  static String _coverPath = '';

  static void _resetSendState() {
    _lastSignature = null;
    _lastIsPlaying = null;
    _lastSentPositionMs = -1000000;
    _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
    _queueList = null;
    _queueJson = '';
    _queueRevision = 0;
    _coverKey = null;
    _coverPath = '';
  }

  /// 启停悬浮窗。开启时原生会校验悬浮窗权限；[requestPermission] 为
  /// true（设置页手动开启）时未授权会拉起授权页并返回 false，false
  /// （自动同步链路）时静默返回 false，避免进 app 就被拉去授权页。
  static Future<bool> setEnabled(
    bool enabled, {
    bool requestPermission = true,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
        'requestPermission': requestPermission,
      });
      final accepted = result == true;
      if (accepted) {
        _lastEnabled = enabled;
        if (!enabled) _resetSendState();
      }
      return accepted;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 查询悬浮窗权限状态（Android 11 以下恒有权限）。
  ///
  /// 这是全局唯一的系统悬浮窗权限（`canDrawOverlays`），迷你播放器浮窗、
  /// 桌面歌词等一切小窗功能共用；权限弹页规范：只在用户手动开启小窗类
  /// 功能时检测并询问跳转授权页，自动链路一律静默。
  static Future<bool> hasOverlayPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 拉起系统悬浮窗授权页（仅设置页手动开启时调用）。
  static Future<void> requestOverlayPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestOverlayPermission');
    } on PlatformException {
      // 授权页拉起失败时静默，开关保持原状。
    } on MissingPluginException {
      // 非 Android 构建没有对应原生实现。
    }
  }

  /// 请求一次状态同步（节流 100ms，且不会让新旧同步任务同时堆积）。
  /// 根节点在播放状态或设置开关变化时调用。
  static void requestSync({bool immediate = false}) {
    final ref = _ref;
    if (ref == null || !Platform.isAndroid) return;
    final enabled =
        ref.read(settingsProvider).valueOrNull?.miniPlayerOverlayEnabled == true;
    if (!enabled) {
      _syncPending = false;
      _syncTimer?.cancel();
      _syncTimer = null;
      // 关闭只发送一次，避免每次进度回调都跨通道。
      if (!_hiddenSent) {
        _hiddenSent = true;
        unawaited(setEnabled(false));
      }
      return;
    }
    _hiddenSent = false;
    _syncPending = true;
    if (immediate) {
      _syncTimer?.cancel();
      _syncTimer = null;
      if (!_syncInFlight) _startSync();
      return;
    }
    if (_syncInFlight || _syncTimer != null) return;
    final elapsed = DateTime.now().difference(_lastSync);
    final delay = elapsed >= const Duration(milliseconds: 100)
        ? Duration.zero
        : const Duration(milliseconds: 100) - elapsed;
    _syncTimer = Timer(delay, () {
      _syncTimer = null;
      if (!_syncInFlight) _startSync();
    });
  }

  static void _startSync() {
    if (_syncInFlight || !_syncPending) return;
    _syncPending = false;
    _syncInFlight = true;
    _lastSync = DateTime.now();
    unawaited(
      _sync().whenComplete(() {
        _syncInFlight = false;
        if (_syncPending) requestSync();
      }),
    );
  }

  static Future<void> _sync() async {
    final ref = _ref;
    if (ref == null) return;
    if (ref.read(settingsProvider).valueOrNull?.miniPlayerOverlayEnabled !=
        true) {
      return;
    }
    final generation = ++_syncGeneration;
    if (_lastEnabled != true) {
      // 自动同步链路（进 app 恢复状态等）永远静默：进 APP 不需要悬浮窗
      // 权限，未授权时不弹授权页，直接把开关同步回关闭；用户想开启时到
      // 设置页/播放页手动打开（手动链路才会检测并询问跳转授权页）。
      final accepted = await setEnabled(true, requestPermission: false);
      if (generation != _syncGeneration) return;
      if (!accepted) {
        _hiddenSent = true;
        _lastEnabled = false;
        final latest = ref.read(settingsProvider).valueOrNull;
        if (latest?.miniPlayerOverlayEnabled == true) {
          unawaited(
            ref
                .read(settingsProvider.notifier)
                .setMiniPlayerOverlayEnabled(false),
          );
        }
        return;
      }
    }

    final state = ref.read(playerProvider);
    final item = state.current;
    final coverPath = await _resolveCoverPath(item);
    if (generation != _syncGeneration) return;
    final appVolume = ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
    final appVolumeMode =
        ref.read(settingsProvider).valueOrNull?.volumeKeyControlsAppVolume ?? true;

    _updateQueue(state.queue);
    final positionMs = state.position.isFinite && state.position > 0
        ? (state.position * 1000).round()
        : 0;
    final durationMs = state.duration.isFinite && state.duration > 0
        ? (state.duration * 1000).round()
        : (item?.durationMs ?? 0);
    final signature = <Object?>[
      item?.path ?? '',
      item?.title ?? '',
      item?.artist ?? '',
      state.isPlaying,
      state.isLoading,
      state.playMode,
      durationMs,
      coverPath,
      state.queueIndex,
      _queueRevision,
      appVolume,
      appVolumeMode,
    ].join('\u0000');
    final now = DateTime.now();
    final positionDelta = (positionMs - _lastSentPositionMs).abs();
    final shouldSend =
        signature != _lastSignature ||
        state.isPlaying != _lastIsPlaying ||
        positionDelta > 500 ||
        (now.difference(_lastSendTime) >= const Duration(milliseconds: 500) &&
            positionDelta > 50);
    if (!shouldSend) return;
    _lastSignature = signature;
    _lastIsPlaying = state.isPlaying;
    _lastSentPositionMs = positionMs;
    _lastSendTime = now;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'title': item?.title ?? '',
        'artist': item?.artist ?? '',
        'isPlaying': state.isPlaying,
        'isLoading': state.isLoading,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'playMode': state.playMode,
        'coverPath': coverPath,
        'queueJson': _queueJson,
        'queueIndex': state.queueIndex,
        'appVolume': appVolume,
        'appVolumeMode': appVolumeMode,
      });
    } on PlatformException {
      // 浮窗属于附加能力，系统回收或引擎销毁时不影响正常播放。
    } on MissingPluginException {
      // 非 Android 构建没有对应原生实现。
    }
  }

  /// 队列仅在引用变化时重建 JSON（播放状态 copyWith 会复用同一 List 实例）。
  static void _updateQueue(List<QueueItem> queue) {
    if (identical(_queueList, queue)) return;
    _queueList = queue;
    _queueJson = jsonEncode([
      for (final item in queue)
        <String, String>{'title': item.title, 'artist': item.artist},
    ]);
    _queueRevision++;
  }

  /// 解析原生可直接 decodeFile 的封面文件路径：本地歌曲走 Rust 封面缓存；
  /// 在线歌曲走 Rust 图片代理（带 Referer 绕过 CDN 防盗链）落盘后返回。
  static Future<String> _resolveCoverPath(QueueItem? item) async {
    final ref = _ref;
    final songPath = item?.path ?? '';
    final coverUrl = normalizeCoverImageUrl(item?.coverUrl);
    final key = '$songPath\u0000$coverUrl';
    if (ref == null || songPath.isEmpty) {
      _coverKey = null;
      _coverPath = '';
      return '';
    }
    if (key == _coverKey) return _coverPath;
    _coverKey = key;
    _coverPath = '';
    try {
      final cacheRoot = await ref.read(appDataDirProvider.future);
      if (coverUrl.isEmpty) {
        final dbPath = await ref.read(dbPathProvider.future);
        final path = await getSongCover(
          dbPath: dbPath,
          cacheRoot: cacheRoot,
          path: songPath,
        );
        if (key == _coverKey) _coverPath = path;
        return _coverPath;
      }
      final file = File('$cacheRoot/mini_player_cover_${coverUrl.hashCode}.img');
      if (!await file.exists() || await file.length() == 0) {
        final dataUrl = await proxyImage(
          url: coverUrl,
          referer: 'https://music.163.com/',
        );
        final comma = dataUrl.indexOf(',');
        if (comma > 0 && dataUrl.substring(0, comma).contains(';base64')) {
          await file.writeAsBytes(
            base64Decode(dataUrl.substring(comma + 1)),
            flush: true,
          );
        }
      }
      if (key == _coverKey && await file.exists() && await file.length() > 0) {
        _coverPath = file.path;
      }
    } catch (_) {
      // 封面属于附加信息，失败时保留原生占位图。
    }
    return _coverPath;
  }
}