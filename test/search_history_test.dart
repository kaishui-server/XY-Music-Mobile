import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/pages/search/search_page.dart';
import 'package:xy_music/src/library/library_provider.dart';
import 'package:xy_music/src/player/player_provider.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  test('搜索结果命中当前歌曲时复用现有播放状态', () {
    const current = QueueItem(
      path: 'plugin://demo/song-1',
      title: '正在播放',
      artist: '歌手',
      album: '专辑',
    );
    const sameSong = Song(
      path: 'plugin://demo/song-1',
      title: '搜索结果',
      artist: '歌手',
      album: '专辑',
      albumKey: '专辑',
      duration: 180,
      format: '网络',
    );
    const otherSong = Song(
      path: 'plugin://demo/song-2',
      title: '另一首歌',
      artist: '歌手',
      album: '专辑',
      albumKey: '专辑',
      duration: 180,
      format: '网络',
    );

    expect(isCurrentSearchSong(current, sameSong), isTrue);
    expect(isCurrentSearchSong(current, otherSong), isFalse);
    expect(isCurrentSearchSong(null, sameSong), isFalse);
  });

  testWidgets('搜索页展示、删除并清空持久化的搜索历史', (tester) async {
    SharedPreferences.setMockInitialValues({
      'network_search_history_v1': ['周杰伦', '林俊杰'],
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enabledMusicPluginsProvider.overrideWith(
            (ref) async => const [
              EnabledMusicPlugin(
                id: 'test-plugin',
                name: '测试插件',
                path: 'test-plugin.js',
              ),
            ],
          ),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('林俊杰'), findsOneWidget);

    await tester.tap(find.byTooltip('删除 周杰伦'));
    await tester.pumpAndSettle();
    expect(find.text('周杰伦'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        'network_search_history_v1',
      ),
      ['林俊杰'],
    );

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        'network_search_history_v1',
      ),
      isEmpty,
    );
  });
}
