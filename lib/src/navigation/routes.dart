import 'package:go_router/go_router.dart';

import '../../pages/home/home_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/statistics/statistics_page.dart';
import '../../pages/settings/about_page.dart';
import '../../pages/settings/remote_library_page.dart';
import '../../pages/settings/plugins_page.dart';
import '../../pages/settings/scan_folders_page.dart';
import '../../pages/settings/logs_page.dart';
import '../../pages/settings/feedback_page.dart';
import '../../pages/playlists/playlists_page.dart';
import '../../pages/playlists/playlist_detail_page.dart';
import '../../pages/recognize/recognize_page.dart';
import 'animated_branch_container.dart';
import 'shell.dart';

/// 主路由：使用 StatefulShellRoute 保持各一级页面状态。
final appRouter = GoRouter(
  initialLocation: '/home',
  routes: [
    StatefulShellRoute(
      builder: (context, state, navigationShell) {
        return AppShell(
          navigationShell: navigationShell,
          currentPath: state.uri.path,
        );
      },
      // 自定义分支容器：替代默认 IndexedStack（瞬切无动画），
      // 用淡入淡出 + 轻微缩放做过渡，同时保留每个 tab 的状态。
      navigatorContainerBuilder: (context, navigationShell, children) {
        return AnimatedBranchContainer(
          currentIndex: navigationShell.currentIndex,
          children: children,
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const HomePage(),
              // 收藏 / 最近作为主页子路由：保留迷你播放条，
              // 并能正确入栈（自带返回按钮、系统返回键回主页）。
              routes: [
                GoRoute(
                  path: 'favorites',
                  builder: (context, state) => const FavoritesPage(),
                ),
                GoRoute(
                  path: 'recent',
                  builder: (context, state) => const RecentPage(),
                ),
                GoRoute(
                  path: 'playlists',
                  builder: (context, state) => const PlaylistsPage(),
                  routes: [
                    GoRoute(
                      path: ':id',
                      builder: (context, state) => PlaylistDetailPage(
                        playlistId: state.pathParameters['id']!,
                      ),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'recognize',
                  builder: (context, state) => const RecognizePage(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              builder: (context, state) => const LibraryPage(),
            ),
            GoRoute(
              path: '/local-music',
              builder: (context, state) => const LibraryPage(initialTab: 0),
            ),
            GoRoute(
              path: '/artists',
              builder: (context, state) => const LibraryPage(initialTab: 1),
            ),
            GoRoute(
              path: '/albums',
              builder: (context, state) => const LibraryPage(initialTab: 2),
            ),
            GoRoute(
              path: '/folders',
              builder: (context, state) => const LibraryPage(initialTab: 3),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/effects',
              builder: (context, state) => const EffectsPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
              // 设置及其子页面统一隐藏迷你播放条。
              routes: [
                GoRoute(
                  path: 'account-services',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.account),
                ),
                GoRoute(
                  path: 'appearance',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.appearance),
                ),
                GoRoute(
                  path: 'playback',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.playback),
                ),
                GoRoute(
                  path: 'playback-detail',
                  builder: (context, state) => const SettingsPage(
                    section: SettingsSection.playbackDetail,
                  ),
                ),
                GoRoute(
                  path: 'lyrics',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.lyrics),
                ),
                GoRoute(
                  path: 'library',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.library),
                ),
                GoRoute(
                  path: 'download',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.download),
                ),
                GoRoute(
                  path: 'other',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.other),
                ),
                GoRoute(
                  path: 'logs-debug',
                  builder: (context, state) =>
                      const SettingsPage(section: SettingsSection.logsDebug),
                ),
                GoRoute(
                  path: 'logs',
                  builder: (context, state) => const LogsPage(),
                ),
                GoRoute(
                  path: 'feedback',
                  builder: (context, state) => const FeedbackPage(),
                ),
                GoRoute(
                  path: 'account',
                  redirect: (context, state) => '/account',
                ),
                GoRoute(
                  path: 'statistics',
                  builder: (context, state) => const StatisticsPage(),
                ),
                GoRoute(
                  path: 'about',
                  builder: (context, state) => const AboutPage(),
                ),
                GoRoute(
                  path: 'remote-library',
                  builder: (context, state) => const RemoteLibraryPage(),
                ),
                GoRoute(
                  path: 'scan-folders',
                  builder: (context, state) => const ScanFoldersPage(),
                ),
                GoRoute(
                  path: 'plugins',
                  builder: (context, state) => const PluginsPage(),
                ),
              ],
            ),
            // 账号页是独立页面，不挂在设置页下面。这样登录状态变化只会
            // 重建账号内容，不会让设置页成为退出登录后的可见父页面。
            GoRoute(
              path: '/account',
              builder: (context, state) => const AccountPage(),
            ),
          ],
        ),
      ],
    ),
    // 播放页为全屏覆盖。
    GoRoute(path: '/player', builder: (context, state) => const PlayerPage()),
    // 搜索页同为全屏覆盖。
    GoRoute(
      path: '/search',
      builder: (context, state) =>
          SearchPage(initialQuery: state.uri.queryParameters['q'] ?? ''),
    ),
  ],
);
