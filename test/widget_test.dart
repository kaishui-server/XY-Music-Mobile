import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/library/library_provider.dart';
import 'package:xy_music/src/navigation/shell.dart';
import 'package:xy_music/src/widgets/cover_image.dart';
import 'package:xy_music/src/widgets/mini_player_bar.dart';
import 'package:xy_music/src/widgets/song_list_view.dart';

void main() {
  testWidgets('移动端歌曲列表展示标题、歌手和操作入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const song = Song(
      path: r'C:\Music\test.flac',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      albumKey: 'test-album',
      duration: 215,
      format: 'flac',
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: SongsListView(songs: [song])),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('测试歌曲'), findsOneWidget);
    expect(find.text('测试歌手 · 测试专辑'), findsOneWidget);
    expect(find.text('03:35'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('搜索结果常驻收藏按钮并在收藏后切换为实心', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const song = Song(
      path: 'plugin://test/song-1',
      title: '网络歌曲',
      artist: '网络歌手',
      album: '网络专辑',
      albumKey: 'network-album',
      duration: 180,
      format: '插件',
      pluginId: 'test-plugin',
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SongsListView(songs: [song], showFavoriteButton: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    await tester.tap(find.byTooltip('收藏'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('歌曲操作面板显示在播放底栏之上', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const song = Song(
      path: r'C:\Music\favorite.flac',
      title: '收藏歌曲',
      artist: '测试歌手',
      album: '测试专辑',
      albumKey: 'favorite-album',
      duration: 180,
      format: 'flac',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: SongsListView(songs: [song])),
                  ),
                ),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: ColoredBox(
                    color: Colors.black,
                    child: SizedBox(width: double.infinity, height: 100),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('歌曲信息').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('网易云封面请求使用浏览器请求头避免 CDN 403', () {
    final headers = coverImageNetworkHeaders(
      'https://p1.music.126.net/cover-key/song.jpg',
    );

    expect(headers?['User-Agent'], contains('Mozilla/5.0'));
    expect(headers?['Referer'], 'https://music.163.com/');
    expect(coverImageNetworkHeaders('https://example.com/cover.jpg'), isNull);
    expect(
      needsCoverImageProxy('https://p1.music.126.net/key/song.jpg'),
      isTrue,
    );
    expect(needsCoverImageProxy('https://example.com/cover.jpg'), isFalse);
  });

  test('网易云旧封面地址自动升级为 HTTPS', () {
    expect(
      normalizeCoverImageUrl('http://p1.music.126.net/cover-key/song.jpg'),
      'https://p1.music.126.net/cover-key/song.jpg',
    );
    expect(
      normalizeCoverImageUrl('//p2.music.126.net/cover-key/song.jpg'),
      'https://p2.music.126.net/cover-key/song.jpg',
    );
    expect(
      normalizeCoverImageUrl('http://example.com/cover.jpg'),
      'http://example.com/cover.jpg',
    );
  });

  test('播放底栏进度对切歌瞬间的异常时长保持安全', () {
    expect(safeMiniPlayerProgress(30, 120), .25);
    expect(safeMiniPlayerProgress(double.nan, 120), 0);
    expect(safeMiniPlayerProgress(10, double.nan), 0);
    expect(safeMiniPlayerProgress(10, 0), 0);
    expect(safeMiniPlayerProgress(200, 120), 1);
  });

  test('设置及其所有子页面隐藏迷你播放栏', () {
    expect(shouldShowMiniPlayerForPath('/settings'), isFalse);
    expect(shouldShowMiniPlayerForPath('/settings/appearance'), isFalse);
    expect(shouldShowMiniPlayerForPath('/settings/library'), isFalse);
    expect(shouldShowMiniPlayerForPath('/settings/plugins'), isFalse);
    expect(shouldShowMiniPlayerForPath('/settings/account'), isFalse);
    expect(shouldShowMiniPlayerForPath('/account'), isFalse);
    expect(shouldShowMiniPlayerForPath('/home'), isTrue);
    expect(shouldShowMiniPlayerForPath('/library'), isTrue);
  });

  testWidgets('移动端侧栏隐藏歌手专辑和歌单列表并保留识曲及歌单管理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: XyMobileSidebar(currentPath: '/home', onNavigate: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('歌手'), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('文件夹'), findsNothing);
    expect(find.textContaining('歌单 ('), findsNothing);
    expect(find.text('听歌识曲'), findsOneWidget);
    expect(find.text('管理全部歌单'), findsOneWidget);
  });
}
