import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';

/// 网络歌手/专辑详情页。
///
/// 分类搜索结果本身只包含摘要信息。页面先立即打开，再在页面内加载歌曲，
/// 避免点击后等待插件接口返回造成明显延迟。
class OnlineCatalogDetailPage extends ConsumerStatefulWidget {
  const OnlineCatalogDetailPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.categoryLabel,
    required this.loadSongs,
  });

  final String title;
  final String subtitle;
  final String coverUrl;
  final String categoryLabel;
  final Future<List<Song>> Function() loadSongs;

  @override
  ConsumerState<OnlineCatalogDetailPage> createState() =>
      _OnlineCatalogDetailPageState();
}

class _OnlineCatalogDetailPageState
    extends ConsumerState<OnlineCatalogDetailPage> {
  List<Song> _songs = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs = await widget.loadSongs();
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = ref.watch(
      playerProvider.select((state) => state.current != null),
    );
    return Scaffold(
      appBar: AppBar(title: Text(widget.categoryLabel)),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _CatalogCover(
                      coverUrl: widget.coverUrl,
                      isArtist: widget.categoryLabel == '歌手',
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            widget.subtitle.trim().isEmpty
                                ? '网络${widget.categoryLabel}'
                                : widget.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _loading ? '正在加载歌曲…' : '${_songs.length} 首歌曲',
                            style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? _LoadError(
                        message: _error.toString().replaceFirst(
                          'Exception: ',
                          '',
                        ),
                        onRetry: _loadSongs,
                      )
                    : _songs.isEmpty
                    ? Center(
                        child: Text(
                          '未找到“${widget.title}”的歌曲',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : SongsListView(
                        songs: _songs,
                        showFavoriteButton: true,
                        padding: EdgeInsets.only(
                          top: 6,
                          bottom:
                              MediaQuery.of(context).padding.bottom +
                              (current ? 104 : 16),
                        ),
                        onPlay: (list, index) => ref
                            .read(libraryProvider.notifier)
                            .playList(list, index),
                      ),
              ),
            ],
          ),
          if (current)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败：$message'),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _CatalogCover extends StatelessWidget {
  const _CatalogCover({required this.coverUrl, required this.isArtist});

  final String coverUrl;
  final bool isArtist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(isArtist ? 44 : 12),
      child: SizedBox(
        width: 92,
        height: 92,
        child: coverUrl.trim().isEmpty
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  isArtist
                      ? Icons.person_outline_rounded
                      : Icons.album_outlined,
                  size: 38,
                  color: scheme.onSurfaceVariant,
                ),
              )
            : Image.network(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    isArtist
                        ? Icons.person_outline_rounded
                        : Icons.album_outlined,
                    size: 38,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}
