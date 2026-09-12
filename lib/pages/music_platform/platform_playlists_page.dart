import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/library/library_provider.dart';
import '../../src/music_platform/platform_api.dart';
import '../../src/music_platform/platform_session.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/lx_playlist_import.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/top_notice.dart';

enum _DuplicatePlaylistAction { merge, keepBoth }

Future<_DuplicatePlaylistAction?> _confirmDuplicatePlaylist(
  BuildContext context,
  String name,
) {
  return showDialog<_DuplicatePlaylistAction>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('歌单已存在'),
      content: Text('检测到导入的$name歌单在本地已有此名称的歌单，是否直接合并？'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _DuplicatePlaylistAction.keepBoth),
          child: const Text('保留两个歌单'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _DuplicatePlaylistAction.merge),
          child: const Text('合并'),
        ),
      ],
    ),
  );
}

/// 第三方平台在线歌单页：展示已登录账号的歌单列表，点击导入到本地。
class PlatformPlaylistsPage extends ConsumerStatefulWidget {
  const PlatformPlaylistsPage({super.key, required this.platform});

  final MusicPlatform platform;

  @override
  ConsumerState<PlatformPlaylistsPage> createState() =>
      _PlatformPlaylistsPageState();
}

class _PlatformPlaylistsPageState
    extends ConsumerState<PlatformPlaylistsPage> {
  List<OnlinePlaylist>? _playlists;
  bool _loading = false;
  String? _error;
  String? _importingId;
  NeteaseApi? _neteaseApi;
  QqMusicApi? _qqApi;
  KugouApi? _kugouApi;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _neteaseApi?.close();
    _qqApi?.close();
    _kugouApi?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final account = ref
        .read(musicPlatformSessionsProvider)
        .valueOrNull
        ?.accountOf(widget.platform);
    if (account == null) {
      setState(() {
        _playlists = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final playlists = switch (widget.platform) {
        MusicPlatform.netease => await (_neteaseApi ??= NeteaseApi())
            .fetchUserPlaylists(account),
        MusicPlatform.qq => await (_qqApi ??= QqMusicApi())
            .fetchUserPlaylists(account.userId),
        MusicPlatform.kugou => await (_kugouApi ??= KugouApi())
            .fetchUserPlaylists(account),
      };
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is PlatformApiException ? error.message : '$error';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 挑一个已启用的洛雪插件来承载导入歌曲：优先选支持当前平台的，
  /// 否则回退第一个洛雪插件。
  EnabledMusicPlugin? _pickLxPlugin(List<EnabledMusicPlugin> plugins) {
    for (final plugin in plugins) {
      if (plugin.isLx &&
          (plugin.lxSources.isEmpty ||
              plugin.lxSources.contains(widget.platform.lxSource))) {
        return plugin;
      }
    }
    for (final plugin in plugins) {
      if (plugin.isLx) return plugin;
    }
    return null;
  }

  /// 洛雪直连导入的 raw 歌曲 → Song（对齐 playlists_page 的 _rawToLxSong）。
  static Song? _rawToLxSong(
    Map<String, dynamic> raw,
    EnabledMusicPlugin plugin,
  ) {
    final title = raw['title']?.toString().trim() ?? '';
    final path = raw['_sourcePath']?.toString() ?? '';
    if (title.isEmpty || path.isEmpty) return null;
    final duration = raw['duration'];
    return Song(
      path: path,
      title: title,
      artist: raw['artist']?.toString() ?? '',
      album: raw['album']?.toString() ?? '',
      albumKey: raw['album']?.toString() ?? '',
      duration: duration is num ? duration.toInt() : 0,
      format: '网络',
      coverUrl: raw['artwork']?.toString(),
      pluginId: plugin.id,
      pluginData: raw,
    );
  }

  Future<void> _import(OnlinePlaylist playlist) async {
    if (_importingId != null) return;
    final plugins =
        ref.read(enabledMusicPluginsProvider).valueOrNull ??
            const <EnabledMusicPlugin>[];
    final plugin = _pickLxPlugin(plugins);
    if (plugin == null) {
      XyNotice.show(
        context,
        message: '请先在 设置 → 插件 中启用洛雪音乐插件后再导入',
        type: XyNoticeType.warning,
      );
      return;
    }
    setState(() => _importingId = playlist.id);
    try {
      final result = await importLxPlaylist(
        source: widget.platform.lxSource,
        idOrUrl: playlist.id,
      );
      final songs = result.songs
          .map((raw) => _rawToLxSong(raw, plugin))
          .whereType<Song>()
          .toList();
      if (songs.isEmpty) throw const PlatformApiException('歌单中没有可导入的歌曲');
      final notifier = ref.read(playlistsProvider.notifier);
      final existing = await notifier.findByName(result.name);
      if (existing != null) {
        if (!mounted) return;
        final action = await _confirmDuplicatePlaylist(context, result.name);
        if (!mounted || action == null) return;
        if (action == _DuplicatePlaylistAction.merge) {
          await notifier.mergeImportedSongs(
            existing.id,
            songs,
            coverUrl: result.coverUrl,
          );
        } else {
          await notifier.create(
            result.name,
            coverUrl: result.coverUrl.isEmpty
                ? songs.first.coverUrl
                : result.coverUrl,
            songs: songs,
          );
        }
      } else {
        await notifier.create(
          result.name,
          coverUrl: result.coverUrl.isEmpty
              ? songs.first.coverUrl
              : result.coverUrl,
          songs: songs,
        );
      }
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '已导入「${result.name}」（${songs.length} 首）',
        type: XyNoticeType.success,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: error
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('PlatformApiException: ', ''),
        type: XyNoticeType.error,
      );
    } finally {
      if (mounted) setState(() => _importingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final account = ref
        .watch(musicPlatformSessionsProvider)
        .valueOrNull
        ?.accountOf(widget.platform);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text('${widget.platform.label}歌单'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: account == null
          ? _buildLoggedOut(scheme)
          : _buildList(scheme, account),
    );
  }

  Widget _buildLoggedOut(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.logout_rounded, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text('该平台尚未登录', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => context.go('/account/music-platform'),
            icon: const Icon(Icons.login_rounded),
            label: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme scheme, MusicPlatformAccount account) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final playlists = _playlists;
    if (playlists == null || playlists.isEmpty) {
      return Center(
        child: Text('暂无歌单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          16, 8, 16, MediaQuery.paddingOf(context).bottom + 24,
        ),
        itemCount: playlists.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          final importing = _importingId == playlist.id;
          return _PlaylistTile(
            playlist: playlist,
            importing: importing || _importingId != null,
            onTap: importing ? null : () => _import(playlist),
          );
        },
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.importing,
    this.onTap,
  });

  final OnlinePlaylist playlist;
  final bool importing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: playlist.coverUrl.isEmpty
                      ? Container(
                          color: scheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.queue_music_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : Image.network(
                          playlist.coverUrl,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: scheme.surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.queue_music_rounded,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (playlist.isFavorite) ...[
                          Icon(
                            Icons.favorite_rounded,
                            size: 14,
                            color: Colors.pinkAccent.shade200,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${playlist.songCount} 首',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (importing)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.download_rounded, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
