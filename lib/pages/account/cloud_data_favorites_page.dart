import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/cloud_data_viewer.dart';
import '../../src/widgets/top_notice.dart';
import 'cloud_data_widgets.dart';

/// 云端收藏列表：只读展示云同步保存的收藏歌曲，
/// 支持单曲删除与批量删除（仅操作云端数据）。
class CloudDataFavoritesPage extends ConsumerStatefulWidget {
  const CloudDataFavoritesPage({super.key});

  @override
  ConsumerState<CloudDataFavoritesPage> createState() =>
      _CloudDataFavoritesPageState();
}

class _CloudDataFavoritesPageState extends ConsumerState<CloudDataFavoritesPage> {
  CloudDataOverview? _overview;
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
      _selectedPaths.clear();
    });
  }

  Future<void> _delete(List<String> paths, String confirmMessage) async {
    if (_deleting || paths.isEmpty) return;
    final confirmed = await showCloudDeleteConfirm(
      context,
      title: '删除云端收藏',
      message: confirmMessage,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      final deleted = await CloudDataViewer.deleteFavorites(
        ref.read(authProvider.notifier),
        paths,
      );
      if (!mounted) return;
      XyNotice.show(context, message: '已删除 $deleted 首云端收藏');
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
        '确定删除云端收藏「${song.title}」吗？',
      );

  Future<void> _deleteSelected() => _delete(
        _selectedPaths.toList(),
        '确定删除选中的 ${_selectedPaths.length} 首云端收藏吗？',
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('云端收藏')),
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
    final favorites = _overview?.favorites ?? const [];
    if (favorites.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.favorite_border, size: 56, color: scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('云端还没有收藏歌曲', style: TextStyle(color: scheme.onSurfaceVariant)),
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
      itemCount: favorites.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return CloudDataBatchBar(
            selectionMode: _selectionMode,
            selectedCount: _selectedPaths.length,
            allSelected: _selectedPaths.length >= favorites.length,
            busy: _deleting,
            onToggleMode: () => setState(() {
              _selectionMode = !_selectionMode;
              if (!_selectionMode) _selectedPaths.clear();
            }),
            onToggleAll: () => setState(() {
              if (_selectedPaths.length >= favorites.length) {
                _selectedPaths.clear();
              } else {
                _selectedPaths
                  ..clear()
                  ..addAll(
                    favorites
                        .map((song) => song.path)
                        .where((path) => path.isNotEmpty),
                  );
              }
            }),
            onDeleteSelected: _deleteSelected,
          );
        }
        final song = favorites[index - 1];
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
