import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../logging/error_context.dart';
import 'boot_location.dart';
import '../../pages/home/home_page.dart';
import '../../pages/explore/explore_page.dart';
import '../../pages/library/library_page.dart';
import '../../pages/library/music_library_page.dart';
import '../../pages/effects/effects_page.dart';
import '../../pages/visualizer/visualizer_page.dart';
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
import '../../pages/cloud/cloud_bind_page.dart';
import '../../pages/cloud/cloud_pan_browser_page.dart';
import '../../pages/cloud/cloud_link_import_page.dart';
import '../../pages/cloud/cloud_password_login_page.dart';
import '../../pages/cloud/cloud_qrcode_login_page.dart';
import '../../pages/cloud/cloud_webview_login_page.dart';
import '../../pages/settings/plugins_page.dart';
import '../../pages/settings/scan_folders_page.dart';
import '../../pages/settings/logs_page.dart';
import '../../pages/settings/feedback_page.dart';
import '../../pages/settings/sponsor_page.dart';
import '../../pages/playlists/playlists_page.dart';
import '../../pages/playlists/playlist_detail_page.dart';
import '../../pages/recognize/recognize_page.dart';
import '../../src/music_platform/platform_session.dart';
import 'animated_branch_container.dart';
import 'animated_page_route.dart';
import 'settings_expand_transition.dart';
import 'shell.dart';

/// 常规页面工厂：转场统一由全局「页面切换动画」设置决定
/// （[xyPageTransition] 按平移 / 层叠 / 淡入淡出分发）。除「设置根页 → 设置
/// 详情页」这一层用展开转场外，其余层级（含设置详情页的下一级）都走这里。
Page<void> _instantPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: xyPageTransitionDuration,
      reverseTransitionDuration: xyPageReverseTransitionDuration,
      transitionsBuilder: xyPageTransition,
      child: child,
    );

/// 设置根页（/settings）专用页面工厂：入场上层仍跟随全局「页面切换动画」，
/// 但本页被设置详情页覆盖时**不再播放二级全局转场**，而是按同一矩形做
/// 挖洞互补裁剪（见 [xySettingsRootCoverTransition]）——矩形之外绘制本页，
/// 矩形之内留给详情页，矩形缩到哪本页就露出到哪，两层不会文字叠加。
Page<void> _settingsRootPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: xyPageTransitionDuration,
      reverseTransitionDuration: xyPageReverseTransitionDuration,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final inbound = xyPageTransition(
          context,
          animation,
          kAlwaysDismissedAnimation,
          child,
        );
        return xySettingsRootCoverTransition(
          context,
          animation,
          secondaryAnimation,
          inbound,
        );
      },
      child: child,
    );

/// 播放详情页 Page：创建 [XyPlayerSheetRoute]（转场参数与手势驱动接口
/// 都定义在路由类上）。
class XyPlayerSheetPage<T> extends Page<T> {
  const XyPlayerSheetPage({required super.key, required this.child});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      XyPlayerSheetRoute<T>(settings: this, builder: (context) => child);
}

/// 播放详情页专属页面工厂：XianYu 式底部滑入/收回转场（见
/// [xyPlayerSheetTransition]），不受全局页面切换模式设置影响。
/// 详情页下滑收起手势需要实时驱动转场控制器，因此不用
/// CustomTransitionPage（拿不到路由控制器），改用自定义 [XyPlayerSheetPage]。
Page<void> _playerSheetPage(GoRouterState state, Widget child) =>
    XyPlayerSheetPage<void>(key: state.pageKey, child: child);

/// 设置项 → 子页面：卡片展开转场。起点取自在设置页被点击的那一行
/// （见 [SettingsExpandOriginRegistry]）。
///
/// 判定口径是「父路由是谁 + 这次导航是否来自设置页的一次行点击」：
/// 只有从设置根页点某一行进入下一级设置详情页时才登记起点、才走纯展开
/// 动画；没有起点说明这不是「设置根页 → 详情页」这一层（深链直达、
/// 搜索直达、侧边栏 / 底栏入口、探索页引导等），直接回退到
/// [_instantPage]，跟随全局「页面切换动画」设置，不做展开。
///
/// 该工厂只用于设置根页的直接下一级（含从设置进入的账号页）。设置详情页
/// 再往下的路由（如任务详情、关于页里的第三方许可）一律 [_instantPage]。
Page<void> _settingsExpandPage(GoRouterState state, Widget child) {
  final origin = SettingsExpandOriginRegistry.take();
  // 没有设置行起点：不属于「设置根页 → 详情页」这一层，按全局转场处理。
  if (origin == null) return _instantPage(state, child);
  // 详情页本体保持透明（与根页共底壳层壁纸），页面直接参与矩形生长 /
  // 收缩（见 [xySettingsExpandTransition]），落定后整页透出壳层壁纸，
  // 观感与进入前一致。壳层浮层（自定义底栏、迷你播放条）绘制在导航器
  // 之上，不受本转场影响，始终正常显示。
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: xySettingsExpandDuration,
    reverseTransitionDuration: xySettingsExpandReverseDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        xySettingsExpandTransition(
          context,
          animation,
          secondaryAnimation,
          child,
          origin,
        ),
    child: child,
  );
}

/// 主路由：使用 StatefulShellRoute 保持各一级页面状态。
///
/// 启动落点跟着用户在「侧栏排序 / 自定义底栏」里配的顺序走（取第一个
/// 可见入口），不再写死首页；`appRouter` 是顶层 `final`，首次读取才
/// 初始化，只要 `main()` 在 `runApp` 之前预热了偏好快照，
/// [resolveBootLocation] 同步拿到的就是用户的真实排序。
final appRouter = GoRouter(
  initialLocation: resolveBootLocation(),
  // 崩溃上下文：记录最近一次导航与当前栈顶页面。release AOT 下异步异常的
  // 堆栈只有几帧挂起点，没有它就无法判断崩在哪一页。
  observers: [ErrorContextObserver()],
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
          // 横滑跟手滑到位后提交分支切换；initialLocation 为 false，
          // 目标分支的页面栈与滚动位置全部保留。
          onBranchSelected: (index) => navigationShell.goBranch(index),
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
              path: '/cloud-bind',
              pageBuilder: (context, state) =>
                  _instantPage(state, const CloudBindPage()),
              routes: [
                GoRoute(
                  path: 'browser/:providerId/:accountId',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    CloudPanBrowserPage(
                      providerId: state.pathParameters['providerId']!,
                      accountId: state.pathParameters['accountId'],
                      selectRoot:
                          state.uri.queryParameters['selectRoot'] == '1',
                    ),
                  ),
                ),
                GoRoute(
                  path: 'link-import',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const CloudLinkImportPage()),
                ),
                GoRoute(
                  path: 'password/:providerId',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    CloudPasswordLoginPage(
                      providerId: state.pathParameters['providerId']!,
                    ),
                  ),
                ),
                GoRoute(
                  path: 'qrcode/:providerId',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    CloudQrcodeLoginPage(
                      providerId: state.pathParameters['providerId']!,
                    ),
                  ),
                ),
                GoRoute(
                  path: 'webview/:providerId',
                  pageBuilder: (context, state) => _instantPage(
                    state,
                    CloudWebviewLoginPage(
                      providerId: state.pathParameters['providerId']!,
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
                  _settingsRootPage(state, const SettingsPage()),
              // 设置及其子页面统一隐藏迷你播放条。
              routes: [
                GoRoute(
                  path: 'tasks',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const TaskManagerPage()),
                  routes: [
                    // 批量任务详情：展示本次批量操作的歌曲列表。
                    // 属「设置详情页的下一级」，转场跟随全局切换模式，
                    // 不再用卡片展开动画。
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
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.account),
                  ),
                ),
                GoRoute(
                  path: 'appearance',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.appearance),
                  ),
                ),
                GoRoute(
                  path: 'layout',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.layout),
                  ),
                ),
                GoRoute(
                  path: 'sidebar-layout',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.sidebarLayout),
                  ),
                ),
                GoRoute(
                  path: 'bottom-bar',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.bottomBar),
                  ),
                ),
                GoRoute(
                  path: 'playback',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.playback),
                  ),
                ),
                GoRoute(
                  path: 'volume',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.volume),
                  ),
                ),
                GoRoute(
                  path: 'playback-detail',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.playbackDetail),
                  ),
                ),
                GoRoute(
                  path: 'lyrics',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.lyrics),
                  ),
                ),
                GoRoute(
                  path: 'desktop-lyrics',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.desktopLyrics),
                  ),
                ),
                GoRoute(
                  path: 'download',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.download),
                  ),
                ),
                GoRoute(
                  path: 'other',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.other),
                  ),
                ),
                GoRoute(
                  path: 'backup',
                  pageBuilder: (context, state) => _settingsExpandPage(
                    state,
                    const SettingsPage(section: SettingsSection.backup),
                  ),
                ),
                GoRoute(
                  path: 'logs',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const LogsPage()),
                ),
                GoRoute(
                  path: 'feedback',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const FeedbackPage()),
                ),
                GoRoute(
                  path: 'account',
                  redirect: (context, state) => '/account?from=settings',
                ),
                GoRoute(
                  path: 'statistics',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const StatisticsPage()),
                ),
                GoRoute(
                  path: 'storage',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const StoragePage()),
                ),
                GoRoute(
                  path: 'about',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const AboutPage()),
                ),
                GoRoute(
                  path: 'sponsor',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const SponsorPage()),
                ),
                GoRoute(
                  path: 'scan-folders',
                  pageBuilder: (context, state) =>
                      _settingsExpandPage(state, const ScanFoldersPage()),
                ),
                GoRoute(
                  path: 'plugins',
                  pageBuilder: (context, state) => _settingsExpandPage(
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
              // 从设置页点进来（from=settings）才算「设置根页 → 详情页」，
              // 用卡片展开动画；从侧边栏等其它入口进来时父路由不是设置根页，
              // 跟随全局「页面切换动画」设置。
              pageBuilder: (context, state) {
                final fromSettings =
                    state.uri.queryParameters['from'] == 'settings';
                final page = AccountPage(showSidebarButton: !fromSettings);
                return fromSettings
                    ? _settingsExpandPage(state, page)
                    : _instantPage(state, page);
              },
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
                                  playlistId: Uri.decodeComponent(
                                    state.pathParameters['id'] ?? '',
                                  ),
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
                          pageBuilder: (context, state) =>
                              _instantPage(state, const CloudDataPluginsPage()),
                        ),
                        GoRoute(
                          path: 'user',
                          pageBuilder: (context, state) =>
                              _instantPage(state, const CloudDataUserPage()),
                        ),
                      ],
                    ),
                  ],
                ),
                // 第三方音乐平台（QQ/网易/酷狗）：登录后可导入在线歌单。
                GoRoute(
                  path: 'music-platform',
                  pageBuilder: (context, state) =>
                      _instantPage(state, const PlatformAccountPage()),
                  routes: [
                    GoRoute(
                      path: 'playlists/:platform',
                      pageBuilder: (context, state) => _instantPage(
                        state,
                        PlatformPlaylistsPage(
                          platform:
                              MusicPlatformX.fromName(
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
    // 播放页为全屏覆盖：底部滑入/收回（不随全局切换模式变化）。
    GoRoute(
      path: '/player',
      pageBuilder: (context, state) =>
          _playerSheetPage(state, const PlayerPage()),
    ),
    // 完整音效页全屏覆盖：从播放页（shell 外路由）push shell 内 branch
    // 会导致空白页，这里注册独立全屏路由供播放页跳转，返回即回播放页。
    GoRoute(
      path: '/effects-page',
      pageBuilder: (context, state) =>
          _instantPage(state, const EffectsPage(showBackButton: true)),
    ),
    // 全屏音乐可视化页：从播放页更多菜单进入。
    GoRoute(
      path: '/visualizer',
      pageBuilder: (context, state) =>
          _instantPage(state, const VisualizerPage()),
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
