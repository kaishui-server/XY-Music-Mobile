// xymusic:// 深链处理。
//
// Android 端由 MainActivity 通过 MethodChannel('com.xymusic.mobile/deeplink')
// 把 intent 的 xymusic://song?... 深链透传到这里：解析歌名/歌手/时长/封面后，
// 先弹「分享预览窗」（封面/歌名/歌手 + 播放/取消），用户点「播放」才进入播放。
// 播放优先在本地曲库按「标题+歌手」匹配（±5s 时长容差）——命中直接用本地
// 文件；未命中再走在线搜索定位（复用插件重连逻辑）。播放后跳转播放页。
// 这样分享落地页点「在 XY Music 中打开」就能拉起 App 并播放分享曲。
///
/// 防重复：`_busy` 保证同一时刻只处理一枚深链，杜绝重复弹窗。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/library_provider.dart';
import '../logging/app_log_store.dart';
import '../player/player_provider.dart';

class XyDeepLink {
  static const MethodChannel _channel = MethodChannel(
    'com.xymusic.mobile/deeplink',
  );

  static bool _initialized = false;

  /// 同一时刻只处理一枚深链：防止冷/热启同链被二次派发时重复弹预览窗。
  static bool _busy = false;

  /// 在应用根组件初始化（仅需一次）。
  static void init(WidgetRef ref, GoRouter router) {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final raw = call.arguments as String?;
        if (raw != null && raw.isNotEmpty) {
          _handle(ref, router, raw);
        }
      }
      return null;
    });

    // 冷启动：创建时可能已有一枚深链暂存在原生侧，主动取一次。
    _channel
        .invokeMethod<String>('getInitialDeepLink')
        .then((raw) {
          if (raw != null && raw.isNotEmpty) {
            _handle(ref, router, raw);
          }
        })
        .catchError((Object _) {});
  }

  static Future<void> _handle(
    WidgetRef ref,
    GoRouter router,
    String raw,
  ) async {
    if (_busy) {
      AppLogStore.instance.add('忽略重复的分享深链: $raw');
      return;
    }
    _busy = true;
    try {
      await _run(ref, router, raw);
    } catch (e, st) {
      AppLogStore.instance.add('分享深链解析异常: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _run(
    WidgetRef ref,
    GoRouter router,
    String raw,
  ) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host != 'song') return;
    final q = uri.queryParameters;
    final title = (q['title'] ?? '').trim();
    if (title.isEmpty) return;
    final artist = (q['singer'] ?? '').trim();
    final durationMs = int.tryParse(q['duration_ms'] ?? '') ?? 0;
    final cover = (q['cover'] ?? '').trim();
    AppLogStore.instance.add('收到分享深链: $raw');

    // 等待本地曲库加载（冷启动时曲库可能仍在后台扫描，最多等 5s）。
    await _waitForLibrary(ref, timeout: const Duration(seconds: 5));
    final local = _tryLocalMatch(ref, title, artist, durationMs);

    // 分享预览窗：封面/歌名/歌手 + 播放/取消。
    final ctx = router.routerDelegate.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final play = await showDialog<bool>(
      context: ctx,
      builder: (dialogContext) => _ShareLinkPreviewDialog(
        title: title,
        artist: artist,
        cover: cover,
        isLocal: local != null,
      ),
    );
    if (play != true) return;

    // 本地命中 → 直接播放本地文件。
    if (local != null) {
      await ref
          .read(libraryProvider.notifier)
          .playList([local], 0);
      if (ctx.mounted) router.push('/player');
      return;
    }

    // 未命中 → 在线搜索兜底（复用插件重连的匹配与解析逻辑）。
    final online = await ref
        .read(playerProvider.notifier)
        .findOnlineReplacement(QueueItem(
          path: '',
          title: title,
          artist: artist,
          album: '',
          durationMs: durationMs,
        ));
    if (online == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
          const SnackBar(content: Text('未找到可播放的音源')),
        );
      }
      return;
    }
    await ref
        .read(playerProvider.notifier)
        .playQueue([online.item], startIndex: 0);
    if (ctx.mounted) router.push('/player');
  }

  /// 等本地曲库结束首轮扫描（冷启动时可能仍在扫，最多等 [timeout]）。
  static Future<void> _waitForLibrary(
    WidgetRef ref, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!ref.read(libraryProvider).loading) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 本地曲库按「标题+歌手」匹配（时长 ±5s 容差；时长缺失仅按前两者）。
  static Song? _tryLocalMatch(
    WidgetRef ref,
    String title,
    String artist,
    int durationMs,
  ) {
    final songs = ref.read(libraryProvider).songs;
    Song? fallback;
    for (final song in songs) {
      if (_norm(song.title) != _norm(title)) continue;
      if (_norm(song.artist) != _norm(artist)) continue;
      if (durationMs > 0 && song.duration > 0) {
        if ((song.duration * 1000 - durationMs).abs() <= 5000) return song;
        continue;
      }
      fallback ??= song;
    }
    return fallback;
  }

  static String _norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

/// 分享预览弹窗：展示分享歌曲信息，用户确认后才播放。
class _ShareLinkPreviewDialog extends StatelessWidget {
  const _ShareLinkPreviewDialog({
    required this.title,
    required this.artist,
    required this.cover,
    required this.isLocal,
  });

  final String title;
  final String artist;
  final String cover;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: cover.isEmpty
                ? Container(
                    width: 140,
                    height: 140,
                    color: scheme.surfaceContainerHighest,
                    child: Icon(Icons.music_note_rounded,
                        size: 56, color: scheme.outline),
                  )
                : Image.network(
                    cover,
                    width: 140,
                    height: 140,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 140,
                      height: 140,
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.music_note_rounded,
                          size: 56, color: scheme.outline),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            artist.isEmpty ? '未知歌手' : artist,
            style: TextStyle(fontSize: 14, color: scheme.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            isLocal ? '来自本地音乐' : '将在线搜索播放',
            style: TextStyle(
              fontSize: 12,
              color: scheme.outline.withValues(alpha: .8),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('播放'),
        ),
      ],
    );
  }
}
