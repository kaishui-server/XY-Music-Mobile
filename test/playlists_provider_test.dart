import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/library/library_provider.dart';
import 'package:xy_music/src/playlists/playlists_provider.dart';

void main() {
  test('旧版本地歌单 JSON 仍可读取', () {
    final playlist = MobilePlaylist.fromJson({
      'id': 'old-list',
      'name': '旧歌单',
      'songPaths': ['D:/Music/song.mp3'],
      'createdAt': '2026-08-22T10:00:00.000',
    });

    expect(playlist.name, '旧歌单');
    expect(playlist.songPaths, ['D:/Music/song.mp3']);
    expect(playlist.songSnapshots, isEmpty);
    expect(playlist.coverUrl, isNull);
  });

  test('网络歌单歌曲快照可完整持久化并恢复播放字段', () {
    const song = Song(
      path: 'plugin://netease/12345',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      albumKey: '测试专辑',
      duration: 215,
      format: '网络',
      coverUrl: 'https://example.com/cover.jpg',
      coverThumbPath: 'D:/cache/cover.jpg',
      pluginId: 'netease',
      pluginData: {'id': 12345, 'quality': '320k'},
      lyricsRaw: '[00:01.00]测试歌词',
    );
    final original = MobilePlaylist(
      id: 'network-list',
      name: '网络歌单',
      songPaths: [song.path],
      createdAt: DateTime(2026, 8, 22),
      coverUrl: song.coverUrl,
      songSnapshots: {song.path: PlaylistSongSnapshot.fromSong(song)},
    );

    final restored = MobilePlaylist.fromJson(original.toJson());
    final restoredSong = restored.songSnapshots[song.path]!.toSong();

    expect(restored.coverUrl, song.coverUrl);
    expect(restoredSong.title, song.title);
    expect(restoredSong.pluginId, song.pluginId);
    expect(restoredSong.pluginData, song.pluginData);
    expect(restoredSong.coverUrl, song.coverUrl);
    expect(restoredSong.coverThumbPath, song.coverThumbPath);
    expect(restoredSong.lyricsRaw, song.lyricsRaw);
  });
}
