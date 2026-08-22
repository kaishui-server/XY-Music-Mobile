import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/favorites/favorites_provider.dart';
import 'package:xy_music/src/player/player_provider.dart';

void main() {
  test('旧收藏网易云歌曲可从插件数据恢复封面', () {
    const snapshot = FavoriteSongSnapshot(
      path: 'plugin://wy/509781655',
      title: '想你就写信',
      artist: '周杰伦',
      album: '中国新歌声',
      duration: 238,
      format: '网络',
      pluginId: 'wy',
      pluginData: {
        'al': {'picId_str': '109951163038292176'},
      },
    );

    expect(
      snapshot.toSong().coverUrl,
      'https://p1.music.126.net/'
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('插件歌曲收藏后可从持久化快照恢复并继续播放', () async {
    const current = QueueItem(
      path: 'plugin://netease/12345',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      durationMs: 198000,
      coverUrl: 'https://example.com/cover.jpg',
      pluginId: 'netease',
      pluginData: {'id': 12345, 'quality': '320k'},
      lyricsRaw: '[00:00.00]测试歌词',
    );
    final first = FavoritesNotifier();
    await first.ready;

    final added = await first.toggle(
      current.path,
      song: FavoriteSongSnapshot.fromQueueItem(current),
    );
    expect(added, isTrue);

    final restored = FavoritesNotifier();
    await restored.ready;
    final snapshot = restored.snapshotFor(current.path);

    expect(restored.state, contains(current.path));
    expect(snapshot, isNotNull);
    expect(snapshot!.title, '测试歌曲');
    expect(snapshot.coverUrl, current.coverUrl);
    expect(snapshot.pluginData, current.pluginData);
    expect(snapshot.toSong().toQueueItem().pluginId, 'netease');

    first.dispose();
    restored.dispose();
  });

  test('本地歌曲收藏仍只保存路径并交给本地曲库读取', () async {
    final notifier = FavoritesNotifier();
    await notifier.ready;
    const path = r'D:\Music\local.flac';

    await notifier.toggle(
      path,
      song: const FavoriteSongSnapshot(
        path: path,
        title: '本地歌曲',
        artist: '歌手',
        album: '专辑',
        duration: 180,
        format: 'FLAC',
      ),
    );

    expect(notifier.state, contains(path));
    expect(notifier.snapshotFor(path), isNull);
    notifier.dispose();
  });

  test('旧版本只有路径的插件收藏可以自动补齐快照', () async {
    const path = 'plugin://qq/song-mid';
    SharedPreferences.setMockInitialValues({
      'favoritePaths': [path],
    });
    final notifier = FavoritesNotifier();
    await notifier.ready;
    expect(notifier.snapshotFor(path), isNull);

    await notifier.rememberSnapshot(
      const FavoriteSongSnapshot(
        path: path,
        title: '旧收藏歌曲',
        artist: '歌手',
        album: '专辑',
        duration: 210,
        format: '插件',
        pluginId: 'qq',
        pluginData: {'songmid': 'song-mid'},
      ),
    );

    final restored = FavoritesNotifier();
    await restored.ready;
    expect(restored.snapshotFor(path)?.title, '旧收藏歌曲');
    notifier.dispose();
    restored.dispose();
  });
}
