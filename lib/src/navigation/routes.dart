import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../pages/home/home_page.dart';
import '../../pages/explore/explore_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/library/music_library_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/search/search_page.dart';
import '../../pages/favorites/favorites_page.dart';
import '../../pages/recent/recent_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/settings/task_manager_page.dart';
import '../../pages/settings/batch_task_detail_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/account/account_page.dart';
import '../../pages/account/account_edit_page.dart';
import '../../pages/account/cloud_sync_page.dart';
import '../../pages/account/cloud_data_page.dart';
import '../../pages/account/cloud_data_playlists_page.dart';
import '../../pages/account/cloud_data_favorites_page.dart';
import '../../pages/account/cloud_data_plugins_page.dart';
import '../../pages/account/cloud_data_user_page.dart';
import '../../pages/music_platform/platform_account_page.dart';
import '../../pages/music_platform/platform_playlists_page.dart';
import '../../pages/statistics/statistics_page.dart';
import '../../pages/settings/about_page.dart';
import '../../pages/settings/storage_page.dart';
import '../../pages/cloud/cloud_music_page.dart';
import '../../pages/cloud/cloud_browser_page.dart';
import '../../pages/settings/plugins_page.dart';
import '../../pages/settings/scan_folders_page.dart';
import '../../pages/settings/logs_page.dart';
import '../../pages/settings/feedback_page.dart';
import '../../pages/playlists/playlists_page.dart';
import '../../pages/playlists/playlist_detail_page.dart';
import '../../pages/recognize/recognize_page.dart';
import '../../src/music_platform/platform_session.dart';
import 'animated_branch_container.dart';
import 'animated_page_route.dart';
import 'shell.dart';

Page<void> _instantPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: xyPageTransitionDuration,
      reverseTransitionDuration: xyPageReverseTransitionDuration,
      transitionsBuilder: xyPageTransition,
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
      // 方向由 AppShell 按用户可见的目的地顺序（底栏/侧栏）先行写入：
      // 分支顺序与可见顺序不一致（「探索」还是首页分支的子路由），
      // 不能用分支下标差推断。
      navigatorContainerBuilder: (context, navigationShell, children) {
        return AnimatedBranchContainer(
          currentIndex: navigationShell.currentIndex,
          direction: branchSwitchDirection.value,
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
              path: '/music-library',
              pageBuilder: (context, state) =>
                  _instantPage(state, const MusicLibraryPage()),
            ),
            GoRoute(
              path: '/cloud-music',
              pageBuilder: (context, state) =>
                  _instantPage(state, const CloudMusicPage()),
              routes: [
                GoRoute(
                  path: 'browse/:sourceId',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    CloudBrowserPage(
                      sourceId: state.pathParameters['sourceId']!,
                    ),
                  ),
                ),
              ],
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
                  path: 'tasks',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const TaskManagerPage(),
                  ),
                  routes: [
                    // 批量任务详情：展示本次批量操作的歌曲列表。
                    GoRoute(
                      path: 'batch/:id',
                      pageBuilder: (context, state) => _instantPage(
                        state,
                        BatchTaskDetailPage(
                          taskId: Uri.decodeComponent(
                            state.pathParameters['id'] ?? '',
                          ),
                        ),
                      ),
                    ),
                  ],
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
                  path: 'sidebar-layout',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.sidebarLayout),
                  ),
                ),
                GoRoute(
                  path: 'bottom-bar',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.bottomBar),
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
                  path: 'backup',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const SettingsPage(section: SettingsSection.backup),
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
                  path: 'storage',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const StoragePage()),
                ),
                GoRoute(
                  path: 'about',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const AboutPage()),
                ),
                GoRoute(
                  path: 'remote-library',
                  redirect: (context, state) => '/cloud-music',
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
                // 编辑账号信息：修改头像/昵称/密码，刷新账号资料。
                GoRoute(
                  path: 'edit',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const AccountEditPage()),
                ),
                GoRoute(
                  path: 'cloud-sync',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const CloudSyncPage()),
                  routes: [
                    GoRoute(
                      path: 'cloud-data',
                      pageBuilder: (context, state) =>
                          _instantPage(state, const CloudDataPage()),
                      routes: [
                        GoRoute(
                          path: 'playlists',
                          pageBuilder: (context, state) => _instantPage(
                            state,
                            const CloudDataPlaylistsPage(),
                          ),
                          routes: [
                            GoRoute(
                              path: ':id',
                              pageBuilder: (context, state) => _instantPage(
                                state,
                                CloudDataPlaylistDetailPage(
                                  playlistId:
                                      Uri.decodeComponent(state.pathParameters['id'] ?? ''),
                                ),
                              ),
                            ),
                          ],
                        ),
                        GoRoute(
                          path: 'favorites',
                          pageBuilder: (context, state) => _instantPage(
                            state,
                            const CloudDataFavoritesPage(),
                          ),
                        ),
                        GoRoute(
                          path: 'plugins',
                          pageBuilder: (context, state) => _instantPage(
                            state,
                            const CloudDataPluginsPage(),
                          ),
                        ),
                        GoRoute(
                          path: 'user',
                          pageBuilder: (context, state) => _instantPage(
                            state,
                            const CloudDataUserPage(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                // 第三方音乐平台（QQ/网易/酷狗）：登录后可导入在线歌单。
                GoRoute(
                  path: 'music-platform',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    const PlatformAccountPage(),
                  ),
                  routes: [
                    GoRoute(
                      path: 'playlists/:platform',
                      pageBuilder: (context, state) => _instantPage(
                        state,
                        PlatformPlaylistsPage(
                          platform: MusicPlatformX.fromName(
                                state.pathParameters['platform'],
                              ) ??
                              MusicPlatform.netease,
                        ),
                      ),
                    ),
                  ],
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
    // 完整音效页全屏覆盖：从播放页（shell 外路由）push shell 内 branch
    // 会导致空白页，这里注册独立全屏路由供播放页跳转，返回即回播放页。
    GoRoute(
      path: '/effects-page',
      pageBuilder: (context, state) =>
          _instantPage(state, const EffectsPage(showBackButton: true)),
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
