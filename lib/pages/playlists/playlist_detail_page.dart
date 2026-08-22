import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/library/library_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/widgets/song_list_view.dart';

class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    MobilePlaylist? playlist;
    for (final item in playlists) {
      if (item.id == playlistId) {
        playlist = item;
        break;
      }
    }
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('歌单')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.go('/home/playlists'),
            child: const Text('返回歌单'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: FutureBuilder<List<Song>>(
        key: ValueKey(Object.hashAll(playlist.songPaths)),
        future: _loadSongs(ref, playlist),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = snapshot.data ?? const <Song>[];
          if (songs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 110),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_off_rounded, size: 52),
                    const SizedBox(height: 12),
                    const Text('歌单中暂无可用歌曲'),
                    const SizedBox(height: 6),
                    Text(
                      '导入文件中的歌曲可能尚未加入本地音乐库',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text('${songs.length} 首歌曲'),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () =>
                          ref.read(libraryProvider.notifier).playList(songs, 0),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SongsListView(
                  songs: songs,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 90),
                  onPlay: (list, index) =>
                      ref.read(libraryProvider.notifier).playList(list, index),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<List<Song>> _loadSongs(WidgetRef ref, MobilePlaylist playlist) async {
    final networkPaths = playlist.songSnapshots.keys.toSet();
    final localPaths = playlist.songPaths
        .where((path) => !networkPaths.contains(path))
        .toList();
    final localSongs = await ref
        .read(libraryProvider.notifier)
        .songsByPaths(localPaths);
    final songsByPath = <String, Song>{
      for (final song in localSongs) song.path: song,
      for (final entry in playlist.songSnapshots.entries)
        entry.key: entry.value.toSong(),
    };
    return [
      for (final path in playlist.songPaths)
        if (songsByPath[path] != null) songsByPath[path]!,
    ];
  }
}
