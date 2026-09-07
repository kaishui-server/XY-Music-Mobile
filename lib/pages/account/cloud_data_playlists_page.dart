import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/cloud_data_viewer.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/top_notice.dart';
import 'cloud_data_widgets.dart';

/// 云端歌单列表：只读展示云同步保存的歌单，点击进入曲目页，
/// 支持单个删除与批量删除（仅操作云端数据）。
class CloudDataPlaylistsPage extends ConsumerStatefulWidget {
  const CloudDataPlaylistsPage({super.key});

  @override
  ConsumerState<CloudDataPlaylistsPage> createState() =>
      _CloudDataPlaylistsPageState();
}

class _CloudDataPlaylistsPageState extends ConsumerState<CloudDataPlaylistsPage> {
  CloudDataOverview? _overview;
  bool _loading = true;
  bool _deleting = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await CloudDataViewer.fetchOverview(
        ref.read(authProvider.notifier),
      );
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AuthException ? error.message : '$error';
      });
    }
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _delete(List<String> ids, String confirmMessage) async {
    if (_deleting || ids.isEmpty) return;
    final confirmed = await showCloudDeleteConfirm(
      context,
      title: '删除云端歌单',
      message: confirmMessage,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      final deleted = await CloudDataViewer.deletePlaylists(
        ref.read(authProvider.notifier),
        ids,
      );
      if (!mounted) return;
      XyNotice.show(context, message: '已删除 $deleted 个云端歌单');
      _exitSelection();
      await _load();
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '删除失败：${error is AuthException ? error.message : '$error'}',
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _deleteOne(CloudPlaylistSummary playlist) => _delete(
        [playlist.id],
        '确定删除云端歌单「${playlist.name}」吗？该歌单内的 ${playlist.songCount} 首歌曲也会一并从云端删除。',
      );

  Future<void> _deleteSelected() {
    final overview = _overview;
    if (overview == null) return Future.value();
    final names = overview.playlists
        .where((pl) => _selectedIds.contains(pl.id))
        .map((pl) => '「${pl.name}」')
        .join('、');
    return _delete(
      _selectedIds.toList(),
      '确定删除选中的 ${_selectedIds.length} 个云端歌单（$names）吗？歌单内的歌曲也会一并从云端删除。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('云端歌单')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildList(scheme),
            ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      );
    }
    final playlists = _overview?.playlists ?? const [];
    if (playlists.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.cloud_off_outlined, size: 56, color: scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('云端还没有歌单，先在本机同步一次吧', style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        12, 8, 12, MediaQuery.paddingOf(context).bottom + 104,
      ),
      // 首项是批量管理按钮栏。
      itemCount: playlists.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return CloudDataBatchBar(
            selectionMode: _selectionMode,
            selectedCount: _selectedIds.length,
            allSelected: _selectedIds.length >= playlists.length,
            busy: _deleting,
            onToggleMode: () => setState(() {
              _selectionMode = !_selectionMode;
              if (!_selectionMode) _selectedIds.clear();
            }),
            onToggleAll: () => setState(() {
              if (_selectedIds.length >= playlists.length) {
                _selectedIds.clear();
              } else {
                _selectedIds
                  ..clear()
                  ..addAll(playlists.map((pl) => pl.id));
              }
            }),
            onDeleteSelected: _deleteSelected,
          );
        }
        final playlist = playlists[index - 1];
        return _playlistTile(scheme, playlist);
      },
    );
  }

  Widget _playlistTile(ColorScheme scheme, CloudPlaylistSummary playlist) {
    final created = playlist.createdAt;
    final selected = _selectedIds.contains(playlist.id);
    return ListTile(
      onTap: _deleting
          ? null
          : _selectionMode
              ? () => setState(() {
                    if (selected) {
                      _selectedIds.remove(playlist.id);
                    } else {
                      _selectedIds.add(playlist.id);
                    }
                  })
              : () => context.push(
                    '/account/cloud-sync/cloud-data/playlists/${Uri.encodeComponent(playlist.id)}',
                  ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: _selectionMode
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            )
          : CoverImage(
              songPath: '',
              imageUrl: playlist.coverUrl.isEmpty ? null : playlist.coverUrl,
              width: 52,
              height: 52,
              radius: 12,
              icon: Icons.queue_music,
            ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${playlist.songCount} 首${created.isNotEmpty ? ' · $created' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _selectionMode
          ? null
          : IconButton(
              onPressed: _deleting ? null : () => _deleteOne(playlist),
              icon: Icon(
                Icons.delete_outline_rounded,
                color: scheme.onSurfaceVariant,
              ),
              tooltip: '删除',
            ),
    );
  }
}

/// 云端歌单曲目页：按需从服务器加载指定歌单的完整歌曲列表，
/// 支持单曲删除与批量删除（仅操作云端数据）。
class CloudDataPlaylistDetailPage extends ConsumerStatefulWidget {
  final String playlistId;
  const CloudDataPlaylistDetailPage({super.key, required this.playlistId});

  @override
  ConsumerState<CloudDataPlaylistDetailPage> createState() =>
      _CloudDataPlaylistDetailPageState();
}

class _CloudDataPlaylistDetailPageState
    extends ConsumerState<CloudDataPlaylistDetailPage> {
  CloudPlaylistDetail? _detail;
  bool _loading = true;
  bool _deleting = false;
  bool _selectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await CloudDataViewer.fetchPlaylistDetail(
        ref.read(authProvider.notifier),
        widget.playlistId,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AuthException ? error.message : '$error';
      });
    }
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  Future<void> _delete(List<String> paths, String confirmMessage) async {
    if (_deleting || paths.isEmpty) return;
    final confirmed = await showCloudDeleteConfirm(
      context,
      title: '删除云端歌曲',
      message: confirmMessage,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      final deleted = await CloudDataViewer.deletePlaylistSongs(
        ref.read(authProvider.notifier),
        widget.playlistId,
        paths,
      );
      if (!mounted) return;
      XyNotice.show(context, message: '已删除 $deleted 首云端歌曲');
      _exitSelection();
      await _load();
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '删除失败：${error is AuthException ? error.message : '$error'}',
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _deleteOne(CloudSongItem song) => _delete(
        [song.path],
        '确定从云端歌单「${_detail?.name ?? ''}」中删除「${song.title}」吗？',
      );

  Future<void> _deleteSelected() => _delete(
        _selectedPaths.toList(),
        '确定删除选中的 ${_selectedPaths.length} 首云端歌曲吗？',
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          _detail?.name ?? '歌单详情',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildList(scheme),
            ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      );
    }
    final detail = _detail;
    if (detail == null) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Center(
            child: Text('云端没有找到这个歌单', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    }
    if (detail.songs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Center(
            child: Text('这个歌单在云端没有歌曲', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        12, 8, 12, MediaQuery.paddingOf(context).bottom + 104,
      ),
      // 首项是批量管理按钮栏。
      itemCount: detail.songs.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return CloudDataBatchBar(
            selectionMode: _selectionMode,
            selectedCount: _selectedPaths.length,
            allSelected: _selectedPaths.length >= detail.songs.length,
            busy: _deleting,
            onToggleMode: () => setState(() {
              _selectionMode = !_selectionMode;
              if (!_selectionMode) _selectedPaths.clear();
            }),
            onToggleAll: () => setState(() {
              if (_selectedPaths.length >= detail.songs.length) {
                _selectedPaths.clear();
              } else {
                _selectedPaths
                  ..clear()
                  ..addAll(
                    detail.songs
                        .map((song) => song.path)
                        .where((path) => path.isNotEmpty),
                  );
              }
            }),
            onDeleteSelected: _deleteSelected,
          );
        }
        final song = detail.songs[index - 1];
        final selected = _selectedPaths.contains(song.path);
        return CloudSongTile(
          index: index,
          song: song,
          selectionMode: _selectionMode,
          selected: selected,
          onTap: _deleting
              ? null
              : _selectionMode && song.path.isNotEmpty
                  ? () => setState(() {
                        if (selected) {
                          _selectedPaths.remove(song.path);
                        } else {
                          _selectedPaths.add(song.path);
                        }
                      })
                  : null,
          onDelete: () => _deleteOne(song),
        );
      },
    );
  }
}
