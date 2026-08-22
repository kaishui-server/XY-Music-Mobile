import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:xy_music/pages/player/player_page.dart';
import 'package:xy_music/src/core/settings.dart';
import 'package:xy_music/src/player/player_provider.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';
import 'package:xy_music/src/recent/recent_provider.dart';

void main() {
  test('单曲歌词偏移以 0.1 秒为单位并限制在正负 10 秒', () {
    expect(clampLyricsOffsetTenths(101), 100);
    expect(clampLyricsOffsetTenths(-101), -100);
    expect(applyLyricsOffset(8, 12), closeTo(9.2, 0.0001));
    expect(playbackPositionForLyric(10, 12), closeTo(8.8, 0.0001));
    expect(lyricsOffsetLabel(12), '提前 1.2 秒');
    expect(lyricsOffsetLabel(-12), '延后 1.2 秒');
  });

  test('自定义定时关闭只接受 30 秒至 12 小时', () {
    expect(isValidSleepTimerDuration(const Duration(seconds: 29)), isFalse);
    expect(isValidSleepTimerDuration(const Duration(seconds: 30)), isTrue);
    expect(isValidSleepTimerDuration(const Duration(hours: 12)), isTrue);
    expect(
      isValidSleepTimerDuration(const Duration(hours: 12, seconds: 1)),
      isFalse,
    );
  });

  test('定时关闭剩余时长按秒更新并在到期时归零', () {
    final now = DateTime(2026, 8, 22, 12, 0, 0);
    final endsAt = now.add(const Duration(seconds: 65));
    expect(sleepTimerRemainingSeconds(endsAt, now: now), 66);
    expect(
      sleepTimerRemainingSeconds(
        endsAt,
        now: now.add(const Duration(seconds: 1)),
      ),
      65,
    );
    expect(
      sleepTimerRemainingSeconds(
        endsAt,
        now: now.add(const Duration(seconds: 65)),
      ),
      1,
    );
    expect(
      sleepTimerRemainingSeconds(
        endsAt,
        now: now.add(const Duration(seconds: 66)),
      ),
      0,
    );
  });

  test('最近播放可忽略损坏记录和兼容字段名', () {
    final rows = decodeRecentHistoryRows(
      '[{"song_path":"/music/a.mp3","played_at":"1700000000000"},'
      '{"songPath":"/music/b.mp3","playedAt":1700000001000},null,42]',
    );
    expect(rows, hasLength(2));
    expect(recentHistorySongPath(rows.first), '/music/a.mp3');
    expect(recentHistoryPlayedAt(rows.first), 1700000000000);
    expect(recentHistorySongPath(rows[1]), '/music/b.mp3');
    expect(recentHistoryPlayedAt(rows[1]), 1700000001000);
    expect(decodeRecentHistoryRows('{"not":"a list"}'), isEmpty);
  });

  test('关联歌词默认使用歌曲名称和作者作为搜索内容', () {
    expect(createDefaultPluginLyricsSearchQuery('  晴天 ', ' 周杰伦  '), '晴天 周杰伦');
    expect(createDefaultPluginLyricsSearchQuery('纯音乐', ''), '纯音乐');
  });

  test('关联歌词搜索不再按当前歌名和歌手严格过滤候选', () {
    const plugin = EnabledMusicPlugin(
      id: 'lyrics-source',
      name: '歌词插件',
      path: '',
    );
    const songs = [
      PluginSearchSong(
        pluginId: 'lyrics-source',
        id: 'cover-version',
        title: '完全不同的版本名',
        artist: '另一位歌手',
        album: '现场专辑',
        durationMs: 180000,
        coverUrl: '',
        rawData: {'id': 'cover-version'},
      ),
      PluginSearchSong(
        pluginId: 'lyrics-source',
        id: 'instrumental',
        title: '纯音乐版',
        artist: '',
        album: '',
        durationMs: 0,
        coverUrl: '',
        rawData: {'id': 'instrumental'},
      ),
    ];

    final options = buildPluginLyricsSearchOptions(plugin, songs);

    expect(options.map((option) => option.id), [
      'lyrics-source:cover-version',
      'lyrics-source:instrumental',
    ]);
  });

  test('本地导入歌曲路径会移除 file URI、编码和引号', () {
    expect(
      normalizeLocalAudioPath(
        '"file:///storage/emulated/0/Music/Test%20Song.mp3"',
        windows: false,
      ),
      '/storage/emulated/0/Music/Test Song.mp3',
    );
    expect(
      normalizeLocalAudioPath("'/storage/emulated/0/Music/a.mp3'"),
      '/storage/emulated/0/Music/a.mp3',
    );
  });

  test('播放会话包含 Rust 必填的 updatedAt 和网络歌曲元数据', () {
    const song = QueueItem(
      path: 'plugin://demo/song-1',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      pluginId: 'demo',
      pluginData: {'id': 'song-1'},
      coverUrl: 'https://example.com/cover.jpg',
    );
    const state = PlaybackState(
      current: song,
      queue: [song],
      queueIndex: 0,
      position: 12.5,
      duration: 180,
      isPlaying: true,
      currentQuality: 'flac',
    );

    final payload = buildPlaybackSessionPayload(
      state: state,
      volume: .8,
      updatedAt: 1700000000000,
    );

    expect(payload['updatedAt'], 1700000000000);
    expect(payload['currentSongPath'], song.path);
    expect(payload['sessionQualityOverride'], 'flac');
    expect((payload['queueSongMeta'] as Map)[song.path]['pluginId'], 'demo');
  });

  test('单曲循环使用播放器原生 LoopMode.one', () {
    expect(audioLoopModeForPlayMode(0), LoopMode.off);
    expect(audioLoopModeForPlayMode(1), LoopMode.one);
    expect(audioLoopModeForPlayMode(2), LoopMode.off);
    expect(audioLoopModeForPlayMode(3), LoopMode.one);
  });

  test('旧会话和损坏的播放模式会被安全归一化', () {
    expect(normalizePlayMode(0), 0);
    expect(normalizePlayMode(1), 1);
    expect(normalizePlayMode(2), 2);
    expect(normalizePlayMode(3), 1);
    expect(normalizePlayMode(-1), 0);
    expect(normalizePlayMode(99), 0);

    const state = PlaybackState(playMode: 3);
    final payload = buildPlaybackSessionPayload(
      state: state,
      volume: 1,
      updatedAt: 1,
    );
    expect(payload['playMode'], 1);
  });

  test('恢复插件歌曲时将 plugin 虚拟路径分类为插件音源', () {
    const pluginSong = QueueItem(
      path: 'plugin://demo/song-1',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      pluginId: 'demo',
      pluginData: {'id': 'song-1'},
    );
    const networkSong = QueueItem(
      path: 'https://example.com/song.mp3',
      title: '网络直链',
      artist: '',
      album: '',
    );

    expect(playbackSourceTypeFor(pluginSong), PlaybackSourceType.plugin);
    expect(playbackSourceTypeFor(networkSong), PlaybackSourceType.networkUrl);
  });

  test('听歌识曲结果使用 LX 音源解析而不是本地文件播放器', () {
    const recognizedSong = QueueItem(
      path: 'lx://kg/HASH128',
      title: '识曲结果',
      artist: '歌手',
      album: '专辑',
      pluginData: {
        'lx': {'songmid': '123', 'source': 'kg', 'hash': 'HASH128'},
      },
    );

    expect(playbackSourceTypeFor(recognizedSong), PlaybackSourceType.lx);
  });

  test('识曲插件回退只接受标题匹配的歌曲，并优先相同歌手和时长', () {
    final exact = recognizedSongMatchScore(
      title: '晴天 (Live)',
      artist: '周杰伦',
      candidateTitle: '晴天',
      candidateArtist: '周杰伦',
      durationMs: 269000,
      candidateDurationMs: 270000,
    );
    final wrongArtist = recognizedSongMatchScore(
      title: '晴天',
      artist: '周杰伦',
      candidateTitle: '晴天',
      candidateArtist: '其他歌手',
    );
    final wrongTitle = recognizedSongMatchScore(
      title: '晴天',
      artist: '周杰伦',
      candidateTitle: '七里香',
      candidateArtist: '周杰伦',
    );

    expect(exact, greaterThan(wrongArtist));
    expect(wrongArtist, greaterThanOrEqualTo(90));
    expect(wrongTitle, -1);
  });

  test('用户选择的音质会排在插件解析候选首位且不会重复', () {
    expect(pluginQualityCandidates('flac').first, 'flac');
    expect(pluginQualityCandidates('flac').where((q) => q == 'flac'), ['flac']);
    expect(pluginQualityCandidates('128k').first, '128k');
  });

  test('插件歌词匹配忽略时长但严格要求歌手一致', () {
    expect(
      pluginLyricsSongMatchScore(
        title: '晴天 (Live)',
        artist: '周杰伦',
        candidateTitle: '晴天',
        candidateArtist: '周杰伦',
      ),
      greaterThanOrEqualTo(70),
    );
    expect(
      pluginLyricsSongMatchScore(
        title: '晴天',
        artist: '周杰伦',
        candidateTitle: '晴天',
        candidateArtist: '其他歌手',
      ),
      -1,
    );
  });
}
