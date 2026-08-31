import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../pages/home/home_page.dart';
import '../../pages/explore/explore_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/settings/download_manager_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/account/cloud_sync_page.dart';
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
import 'animated_page_route.dart';
import 'shell.dart';

Page<void> _instantPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: xyPageTransitionDuration,
      reverseTransitionDuration: xyPageReverseTransitionDuration,
      transitionsBuilder: xyHorizontalPageTransition,
      child: child,
    );

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
              pageBuilder: (context, state) =>
                  _instantPage(state, const HomePage()),
              // 收藏 / 最近作为主页子路由：保留迷你播放条，
              // 并能正确入栈（自带返回按钮、系统返回键回主页）。
              routes: [
                GoRoute(
                  path: 'favorites',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const FavoritesPage()),
                ),
                GoRoute(
                  path: 'recent',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const RecentPage()),
                ),
                GoRoute(
                  path: 'playlists',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const PlaylistsPage()),
                  routes: [
                    GoRoute(
                      path: ':id',
                      pageBuilder: (context, state) => _instantPage(
                        state,
                        PlaylistDetailPage(
                          playlistId: state.pathParameters['id']!,
                          autoFocusSearch:
                              state.uri.queryParameters['search'] == '1',
                        ),
                      ),
                    ),
                  ],
                ),
                GoRoute(
                  path: 'recognize',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const RecognizePage()),
                ),
                GoRoute(
                  path: 'explore',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const ExplorePage()),
                  routes: [
                    GoRoute(
                      path: 'recommendations',
                      pageBuilder: (context, state) => _instantPage(
                        state,
                        const ExploreRecommendationsPage(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              pageBuilder: (context, state) =>
                  _instantPage(state, const LibraryPage()),
            ),
            GoRoute(
              path: '/local-music',
              pageBuilder: (context, state) =>
                  _instantPage(state, const LibraryPage(initialTab: 0)),
            ),
            GoRoute(
              path: '/artists',
              pageBuilder: (context, state) =>
                  _instantPage(state, const LibraryPage(initialTab: 1)),
            ),
            GoRoute(
              path: '/albums',
              pageBuilder: (context, state) =>
                  _instantPage(state, const LibraryPage(initialTab: 2)),
            ),
            GoRoute(
              path: '/folders',
              pageBuilder: (context, state) =>
                  _instantPage(state, const LibraryPage(initialTab: 3)),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/effects',
              pageBuilder: (context, state) =>
                  _instantPage(state, const EffectsPage()),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) =>
                  _instantPage(state, const SettingsPage()),
              // 设置及其子页面统一隐藏迷你播放条。
              routes: [
                GoRoute(
                  path: 'downloads',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const DownloadManagerPage(),
                  ),
                ),
                GoRoute(
                  path: 'account-services',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.account),
                  ),
                ),
                GoRoute(
                  path: 'appearance',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.appearance),
                  ),
                ),
                GoRoute(
                  path: 'layout',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.layout),
                  ),
                ),
                GoRoute(
                  path: 'playback',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.playback),
                  ),
                ),
                GoRoute(
                  path: 'playback-detail',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.playbackDetail),
                  ),
                ),
                GoRoute(
                  path: 'lyrics',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.lyrics),
                  ),
                ),
                GoRoute(
                  path: 'desktop-lyrics',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.desktopLyrics),
                  ),
                ),
                GoRoute(
                  path: 'library',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.library),
                  ),
                ),
                GoRoute(
                  path: 'download',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.download),
                  ),
                ),
                GoRoute(
                  path: 'other',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.other),
                  ),
                ),
                GoRoute(
                  path: 'logs-debug',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.logsDebug),
                  ),
                ),
                GoRoute(
                  path: 'logs',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const LogsPage()),
                ),
                GoRoute(
                  path: 'feedback',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const FeedbackPage()),
                ),
                GoRoute(
                  path: 'account',
                  redirect: (context, state) => '/account?from=settings',
                ),
                GoRoute(
                  path: 'statistics',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const StatisticsPage()),
                ),
                GoRoute(
                  path: 'about',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const AboutPage()),
                ),
                GoRoute(
                  path: 'remote-library',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const RemoteLibraryPage()),
                ),
                GoRoute(
                  path: 'scan-folders',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const ScanFoldersPage()),
                ),
                GoRoute(
                  path: 'plugins',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    PluginsPage(
                      showSidebarButton:
                          state.uri.queryParameters['from'] == 'sidebar',
                    ),
                  ),
                ),
              ],
            ),
            // 账号页是独立页面，不挂在设置页下面。这样登录状态变化只会
            // 重建账号内容，不会让设置页成为退出登录后的可见父页面。
            GoRoute(
              path: '/account',
              pageBuilder: (context, state) => _instantPage(
                state,
                AccountPage(
                  showSidebarButton:
                      state.uri.queryParameters['from'] != 'settings',
                ),
              ),
              routes: [
                GoRoute(
                  path: 'cloud-sync',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const CloudSyncPage()),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
    // 播放页为全屏覆盖。
    GoRoute(
      path: '/player',
      pageBuilder: (context, state) => _instantPage(state, const PlayerPage()),
    ),
    // 搜索页同为全屏覆盖。
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _instantPage(
        state,
        SearchPage(initialQuery: state.uri.queryParameters['q'] ?? ''),
      ),
    ),
  ],
);
