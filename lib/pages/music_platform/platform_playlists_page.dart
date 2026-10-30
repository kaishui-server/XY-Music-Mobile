import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/library/library_provider.dart';
import '../../src/music_platform/platform_api.dart';
import '../../src/music_platform/platform_session.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/playlists/playlist_sync.dart';
import '../../src/plugins/lx_playlist_import.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/cover_image.dart';
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

  /// 挑一个支持酷狗的歌单导入插件（baka / MusicFree 族，非洛雪）。
  /// 按插件名 / ID / 订阅地址中的酷狗特征匹配；未启用酷狗插件时返回
  /// null，由调用方提示用户。
  EnabledMusicPlugin? _pickKgPlugin(List<EnabledMusicPlugin> plugins) {
    for (final plugin in plugins) {
      if (plugin.isLx) continue;
      final haystack =
          '${plugin.name} ${plugin.id} ${plugin.sourceUrl}'.toLowerCase();
      if (haystack.contains('kugou') || haystack.contains('酷狗')) {
        return plugin;
      }
    }
    return null;
  }

  /// 酷狗平台歌单 ID → 插件回退输入：自建/我喜欢歌单为 `id_<specialid>`
  /// 形式，剥掉前缀还原纯数字 specialid，从而命中 plugin_runtime 的
  /// 纯数字回退（importMusicSheet 失败后走 getMusicSheetInfo 详情分页）；
  /// 收藏歌单的 gcid 原样传递。
  static String _kgFallbackInput(String id) {
    final match = RegExp(r'^id_(\d+)$').firstMatch(id);
    return match?.group(1) ?? id;
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

  /// v5 special song 的 filename 形如「歌手 - 歌名」，singer_name 缺失
  /// 时从 filename 拆出歌手名（歌名由 ori_audio_name/name 承担）。
  static String _kgSingerFromFilename(String? filename) {
    if (filename == null || filename.isEmpty) return '';
    final idx = filename.indexOf(' - ');
    if (idx <= 0) return '';
    return filename.substring(0, idx).trim();
  }

  /// 登录态曲目接口的原始条目 → 洛雪 raw（对齐 lx_playlist_import 的
  /// _lxSong 酷狗字段）。播放走 `lx://kg/<hash>` 由洛雪插件取链。
  static Map<String, dynamic> _kgCloudTrackToLxRaw(Map<String, dynamic> item) {
    final hash = (item['hash']?.toString() ?? '').toUpperCase();
    final name =
        item['ori_audio_name']?.toString() ?? item['name']?.toString() ?? '';
    // 兼容两种酷狗取曲响应：登录态网关（singername/duration/album_name）
    // 与 v5 special song（singer_name/timeLen，filename 为「歌手 - 歌名」）。
    final singer =
        item['singername']?.toString() ??
        item['singer_name']?.toString() ??
        _kgSingerFromFilename(item['filename']?.toString());
    final album =
        item['album_name']?.toString() ?? item['albumname']?.toString() ?? '';
    final durationRaw =
        item['duration'] is num
            ? item['duration'] as num
            : item['timeLen'] is num
            ? item['timeLen'] as num
            : 0;
    final duration = durationRaw.toInt();
    var cover = item['cover']?.toString() ?? item['img']?.toString() ?? '';
    if (cover.contains('{size}')) cover = cover.replaceAll('{size}', '240');
    return {
      'id': hash,
      'title': name,
      'artist': singer,
      'album': album,
      if (duration > 0) 'duration': duration,
      if (cover.isNotEmpty) 'artwork': cover,
      '_sourcePath': 'lx://kg/${Uri.encodeComponent(hash)}',
      'lx': {
        'songmid': hash,
        'source': 'kg',
        'hash': hash,
        'name': name,
        'singer': singer,
        'albumName': album,
      },
    };
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
      var importedName = '';
      var importedCover = '';
      var songs = <Song>[];
      // 酷狗：登录态曲目接口优先。列表页的 gcid 来自云收藏登录接口，
      // 曲目必须走同一登录态体系；此前经 mobiles 公开接口取曲，自建/
      // 私密歌单公开库查不到时会被兜底返回热门歌单（内容张冠李戴）。
      // id_<specialid> 形态（无 gcid 的自建条目，含「我喜欢」）先经
      // specialid→global 换算出 gcid，同样走登录态取曲。
      if (widget.platform == MusicPlatform.kugou) {
        final kgAccount = ref
            .read(musicPlatformSessionsProvider)
            .valueOrNull
            ?.accountOf(MusicPlatform.kugou);
        if (kgAccount != null) {
          // 登录态取曲优先；失败（pubsongs 网关对失效 token 返回
          // 20010、mobilecdn v5 域证书失效等）时走公开回退链
          // kgOnlinePlaylistTracks——全链路主键查询，无兜底热门风险。
          if (playlist.id.startsWith('id_')) {
            try {
              final specialId = playlist.id.substring(3);
              final tracks = await KugouApi().fetchSpecialTracks(specialId);
              songs = tracks
                  .map(_kgCloudTrackToLxRaw)
                  .map((raw) => _rawToLxSong(raw, plugin))
                  .whereType<Song>()
                  .toList();
            } catch (_) {
              // v5 special song 公开域已不可达，走回退链。
            }
          } else {
            try {
              final tracks = await KugouApi().fetchCloudPlaylistTracks(
                kgAccount,
                playlist.id,
              );
              songs = tracks
                  .map(_kgCloudTrackToLxRaw)
                  .map((raw) => _rawToLxSong(raw, plugin))
                  .whereType<Song>()
                  .toList();
            } catch (_) {
              // 登录态网关校验失败（如 20010），走回退链。
            }
          }
          if (songs.isEmpty) {
            final fallback = await kgOnlinePlaylistTracks(playlist.id);
            songs = fallback.songs
                .map((raw) => _rawToLxSong(raw, plugin))
                .whereType<Song>()
                .toList();
          }
          if (songs.isEmpty) {
            throw const PlatformApiException(
              '酷狗未返回该歌单的曲目，导入已取消',
            );
          }
          // 名字/封面用列表页数据（列表与曲目同源酷狗体系，正确）；
          // 公开详情接口返回的名字可能是兜底歌单的，不能覆盖。
          importedName = playlist.name;
          importedCover = playlist.coverUrl;
        }
      }
      if (songs.isEmpty) {
        try {
          final result = await importLxPlaylist(
            source: widget.platform.lxSource,
            idOrUrl: playlist.id,
          );
          importedName = result.name;
          importedCover = result.coverUrl;
          songs = result.songs
              .map((raw) => _rawToLxSong(raw, plugin))
              .whereType<Song>()
              .toList();
        } catch (_) {
          // 洛雪直连失败（详情接口异常 / specialid→global 换算失败），
          // 保留给酷狗插件回退；其它平台直接透出下方“歌单为空”提示。
        }
      }
      // 酷狗自建/我喜欢歌单经 id_<specialid>、收藏歌单经 gcid 传入，
      // 洛雪直连偶发拉不到曲目（用户实测提示“歌单为空”）。回退到
      // 酷狗插件（baka / MusicFree）的详情路径：plugin_runtime 的
      // importPlaylist 对纯数字 ID 已有 importMusicSheet 失败后回退
      // getMusicSheetInfo 分页的逻辑（酷狗 kg.js 支持），此处复用该
      // 入口补齐平台在线歌单页的缺口。
      if (songs.isEmpty && widget.platform == MusicPlatform.kugou) {
        final kgPlugin = _pickKgPlugin(plugins);
        if (kgPlugin == null) {
          throw const PlatformApiException(
            '洛雪直连导入失败，且未启用酷狗音源插件，请在 设置 → 插件 中启用酷狗插件后重试',
          );
        }
        final imported = await ref
            .read(pluginRuntimeProvider)
            .importPlaylist(kgPlugin, _kgFallbackInput(playlist.id));
        importedName = imported.name;
        importedCover = imported.coverUrl;
        songs = imported.songs
            .map(
              (item) => pluginSearchSongToPlaylistSong(kgPlugin, item),
            )
            .whereType<Song>()
            .toList();
      }
      if (songs.isEmpty) throw const PlatformApiException('歌单中没有可导入的歌曲');
      final notifier = ref.read(playlistsProvider.notifier);
      final existing = await notifier.findByName(importedName);
      if (existing != null) {
        if (!mounted) return;
        final action = await _confirmDuplicatePlaylist(context, importedName);
        if (!mounted || action == null) return;
        if (action == _DuplicatePlaylistAction.merge) {
          await notifier.mergeImportedSongs(
            existing.id,
            songs,
            coverUrl: importedCover,
          );
        } else {
          await notifier.create(
            importedName,
            coverUrl: importedCover.isEmpty
                ? songs.first.coverUrl
                : importedCover,
            songs: songs,
          );
        }
      } else {
        await notifier.create(
          importedName,
          coverUrl: importedCover.isEmpty
              ? songs.first.coverUrl
              : importedCover,
          songs: songs,
        );
      }
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '已导入「$importedName」（${songs.length} 首）',
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
                          // 网易等音源 CDN 对 Dart 默认 UA 返回 403，
                          // 需带浏览器请求头。
                          headers: coverImageNetworkHeaders(
                            playlist.coverUrl,
                          ),
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
                // 导入条目图标：与下载动作区分（5550）。
                Icon(Icons.playlist_add_rounded, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
