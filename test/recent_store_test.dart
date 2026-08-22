import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/recent/recent_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'network recent snapshot survives persistence and keeps plugin data',
    () async {
      const snapshot = RecentSongSnapshot(
        path: 'plugin://netease/123',
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        durationMs: 185000,
        playedAt: 1700000000000,
        pluginId: 'netease',
        pluginData: {'id': 123, 'quality': '320k'},
        coverUrl: 'https://example.com/cover.jpg',
      );

      await rememberRecentSongSnapshot(snapshot);
      final restored = (await loadRecentSongSnapshots())[snapshot.path];

      expect(restored, isNotNull);
      expect(restored!.title, snapshot.title);
      expect(restored.artist, snapshot.artist);
      expect(restored.pluginId, snapshot.pluginId);
      expect(restored.pluginData, snapshot.pluginData);
      expect(restored.coverUrl, snapshot.coverUrl);
    },
  );

  test(
    'clearing recent snapshots removes persisted network metadata',
    () async {
      await rememberRecentSongSnapshot(
        const RecentSongSnapshot(
          path: 'https://example.com/audio.mp3',
          title: 'Network song',
          artist: 'Artist',
          album: '',
          durationMs: 1000,
          playedAt: 1700000000000,
        ),
      );

      await clearRecentSongSnapshots();

      expect(await loadRecentSongSnapshots(), isEmpty);
    },
  );
}
