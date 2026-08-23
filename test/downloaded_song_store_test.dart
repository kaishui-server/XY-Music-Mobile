import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/player/downloaded_song_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('下载歌曲快照保存本地关联所需的完整元数据', () async {
    const snapshot = DownloadedSongSnapshot(
      path: '/downloads/周杰伦 - 晴天.flac',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      durationMs: 269000,
      downloadedAt: 123456,
      coverUrl: '/covers/晴天.jpg',
      lyricsRaw: '[00:00.00]晴天',
    );

    await rememberDownloadedSongSnapshot(snapshot);
    final loaded = await loadDownloadedSongSnapshots();

    expect(loaded, hasLength(1));
    expect(loaded.single.path, snapshot.path);
    expect(loaded.single.title, snapshot.title);
    expect(loaded.single.artist, snapshot.artist);
    expect(loaded.single.durationMs, snapshot.durationMs);
    expect(loaded.single.lyricsRaw, snapshot.lyricsRaw);
  });
}
