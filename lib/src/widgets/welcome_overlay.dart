import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../ui/xy_theme.dart';

/// RGB 反转（alpha 保留）：深色模式下把深色 Logo 反色为白色。
const _invertColorFilter = ColorFilter.matrix([
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
]);

/// 欢迎页 Logo：透明底、无框，直接贴合向导背景。
class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo();

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/icon/app_icon.png',
    width: 132,
    height: 132,
    filterQuality: FilterQuality.medium,
  );
}

/// 首次启动欢迎/初始化向导：由应用根节点（MaterialApp.builder）叠加，
/// 覆盖侧边栏、底栏与全部页面。背景透明，直接贴合应用全局背景。
///
/// 两步流程：
/// 1. 欢迎页 —— Logo（无框透明）+ 大标题「欢迎使用 XY Music」+
///    「继续」/「稍后设置」。
/// 2. 底栏设置 —— 底栏预览 + 「启动底栏」开关 + 底栏项目选择 + 「完成」。
///
/// 「稍后设置」与「完成」都会写入 welcomeSetupCompleted，之后不再出现。
class WelcomeOverlay extends ConsumerStatefulWidget {
  const WelcomeOverlay({super.key});

  @override
  ConsumerState<WelcomeOverlay> createState() => _WelcomeOverlayState();
}

class _WelcomeOverlayState extends ConsumerState<WelcomeOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );

  int _step = 0;

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// 结束向导：先播放淡出动画，再落盘完成标记（标记写入后根节点移除
  /// 本覆盖层）。
  void _finish() {
    if (_exit.isAnimating || _exit.isCompleted) return;
    _exit.forward().whenComplete(() {
      if (!mounted) return;
      unawaited(
        ref.read(settingsProvider.notifier).completeWelcomeSetup(),
      );
    });
  }

  void _next() {
    setState(() => _step = 1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _exit]),
      builder: (context, _) {
        final enter = CurvedAnimation(parent: _enter, curve: Curves.easeOut);
        return IgnorePointer(
          ignoring: _exit.status != AnimationStatus.dismissed,
          child: FadeTransition(
            opacity: Tween(begin: 1.0, end: 0.0).animate(
              CurvedAnimation(parent: _exit, curve: Curves.easeIn),
            ),
            // 不透明背景（微渐变）：向导是独立页面，不透出底下的首页、
            // 侧边栏与底栏。Material 提供主题默认文字样式——向导位于
            // Navigator 之外，若缺 Material 祖先，裸 Text 会回退到根
            // 字体链（不含中文字形），每个字渲染成黄色双下划线。
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surface,
                    Color.lerp(
                      scheme.surface,
                      scheme.brightness == Brightness.dark
                          ? Colors.black
                          : scheme.primary,
                      scheme.brightness == Brightness.dark ? 0.12 : 0.04,
                    )!,
                  ],
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 24,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.03),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _step == 0
                            ? _WelcomeStep(
                                key: const ValueKey('welcome-step-0'),
                                enter: enter,
                                onContinue: _next,
                                onSkip: _finish,
                              )
                            : _BottomBarStep(
                                key: const ValueKey('welcome-step-1'),
                                enter: enter,
                                onFinish: _finish,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 元素渐入：按 [begin]~[end] 区间取整体入场动画的切片，带轻微上移。
class _StaggerIn extends StatelessWidget {
  const _StaggerIn({
    required this.enter,
    required this.begin,
    required this.end,
    required this.child,
  });

  final Animation<double> enter;
  final double begin;
  final double end;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = Interval(begin, end, curve: Curves.easeOutCubic).transform(
      enter.value,
    );
    return Opacity(
      opacity: curved.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - curved.clamp(0.0, 1.0)) * 22),
        child: child,
      ),
    );
  }
}

/// 第一步：欢迎页。
class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({
    super.key,
    required this.enter,
    required this.onContinue,
    required this.onSkip,
  });

  final Animation<double> enter;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 36),
        _StaggerIn(
          enter: enter,
          begin: 0,
          end: 0.38,
          // 深色模式反色为白色 Logo，浅色模式保持原色。
          child: scheme.brightness == Brightness.dark
              ? const ColorFiltered(
                  colorFilter: _invertColorFilter,
                  child: _WelcomeLogo(),
                )
              : const _WelcomeLogo(),
        ),
        const SizedBox(height: 34),
        _StaggerIn(
          enter: enter,
          begin: 0.14,
          end: 0.5,
          child: Text(
            '欢迎使用 XY Music',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: scheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _StaggerIn(
          enter: enter,
          begin: 0.24,
          end: 0.6,
          child: Text(
            '是否先进行初始化设置？',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 56),
        _StaggerIn(
          enter: enter,
          begin: 0.34,
          end: 0.7,
          child: SizedBox(
            width: 272,
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: onContinue,
              child: const Text('继续'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _StaggerIn(
          enter: enter,
          begin: 0.42,
          end: 0.78,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              minimumSize: const Size(160, 44),
            ),
            onPressed: onSkip,
            child: const Text('稍后设置', style: TextStyle(fontSize: 14.5)),
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

/// 第二步：底栏设置。
class _BottomBarStep extends ConsumerWidget {
  const _BottomBarStep({
    super.key,
    required this.enter,
    required this.onFinish,
  });

  final Animation<double> enter;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final itemIds = settings?.bottomBarItemIds ?? const <String>[];
    final enabled =
        (settings?.bottomBarEnabled ?? false) && itemIds.length >= 2;
    final showLabels = settings?.bottomBarShowLabels ?? true;
    final candidates = normalizeSidebarItemOrder(
      settings?.sidebarItemOrder ?? kDefaultSidebarItemOrder,
    );

    Future<void> toggleItem(String id) async {
      final notifier = ref.read(settingsProvider.notifier);
      final selected = [...itemIds];
      if (selected.contains(id)) {
        await notifier.setBottomBarItems(
          selected.where((item) => item != id).toList(),
        );
      } else {
        await notifier.setBottomBarItems([...selected, id]);
      }
    }

    Future<void> toggleBar(bool value) async {
      final notifier = ref.read(settingsProvider.notifier);
      if (value) {
        // 开启时不足 2 项先补默认项（首页 + 音乐库），再开启底栏。
        if (itemIds.length < 2) {
          await notifier.setBottomBarItems([
            kSidebarHome,
            kSidebarMusicLibrary,
          ]);
        } else {
          await notifier.setBottomBarEnabled(true);
        }
      } else {
        await notifier.setBottomBarEnabled(false);
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        _StaggerIn(
          enter: enter,
          begin: 0,
          end: 0.4,
          child: _BottomBarPreview(
            itemIds: itemIds,
            enabled: enabled,
            showLabels: showLabels,
          ),
        ),
        const SizedBox(height: 34),
        _StaggerIn(
          enter: enter,
          begin: 0.1,
          end: 0.46,
          child: Text(
            '是否启用底栏？',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 30),
        _StaggerIn(
          enter: enter,
          begin: 0.18,
          end: 0.54,
          child: _SwitchCard(
            title: '启用底栏',
            subtitle: '在屏幕底部悬浮显示常用入口',
            value: enabled,
            onChanged: (value) => unawaited(toggleBar(value)),
          ),
        ),
        const SizedBox(height: 12),
        _StaggerIn(
          enter: enter,
          begin: 0.24,
          end: 0.6,
          child: _SwitchCard(
            title: '显示底栏文字',
            subtitle: '关闭后底栏仅显示图标',
            value: showLabels,
            onChanged: (value) => unawaited(
              ref
                  .read(settingsProvider.notifier)
                  .setBottomBarShowLabels(value),
            ),
          ),
        ),
        const SizedBox(height: 22),
        _StaggerIn(
          enter: enter,
          begin: 0.3,
          end: 0.66,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 10),
                child: Text(
                  '底栏项目（2-5 个）',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              SizedBox(
                width: 272,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final id in candidates)
                      _ItemChip(
                        id: id,
                        selected: itemIds.contains(id),
                        onTap: () => unawaited(toggleItem(id)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        _StaggerIn(
          enter: enter,
          begin: 0.36,
          end: 0.72,
          child: SizedBox(
            width: 272,
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: onFinish,
              child: const Text('完成'),
            ),
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

/// 向导中的设置开关卡片：标题 + 说明 + 右侧滑动开关。
class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 272,
      padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.72 : 0.86,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.brightness == Brightness.dark
              ? XyColors.darkBorder
              : XyColors.lightBorder,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 底栏预览：复刻 XyBottomBar 的玻璃卡片样式，随选择实时变化。
class _BottomBarPreview extends StatelessWidget {
  const _BottomBarPreview({
    required this.itemIds,
    required this.enabled,
    required this.showLabels,
  });

  final List<String> itemIds;
  final bool enabled;
  final bool showLabels;

  static const _meta = <String, (String, IconData)>{
    kSidebarHome: ('首页', Icons.home_outlined),
    kSidebarExplore: ('探索', Icons.explore_outlined),
    kSidebarMusicLibrary: ('音乐库', Icons.library_music_outlined),
    kSidebarPlugins: ('插件管理', Icons.extension_outlined),
    kSidebarAccount: ('账号', Icons.account_circle_outlined),
    kSidebarRecognize: ('听歌识曲', Icons.mic_none_rounded),
    kSidebarDownloads: ('下载管理', Icons.download_rounded),
    kSidebarSettings: ('设置', Icons.settings_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final ids = itemIds.length >= 2
        ? itemIds
        : const [kSidebarHome, kSidebarMusicLibrary];
    final items = [for (final id in ids) ?_meta[id]];
    return IgnorePointer(
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(XyRadii.large),
          child: BackdropFilter.grouped(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              width: 272,
              height: 60,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: dark ? .34 : .48),
                borderRadius: BorderRadius.circular(XyRadii.large),
                border: Border.all(
                  color: dark ? XyColors.darkBorder : XyColors.lightBorder,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.3 : 0.09),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  for (final (index, item) in items.indexed)
                    Expanded(
                      child: showLabels
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  item.$2,
                                  size: 22,
                                  color: index == 0
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  item.$1,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: index == 0
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: index == 0
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            )
                          // 关闭文字后仅显示居中图标（紧凑样式）。
                          : Icon(
                              item.$2,
                              size: 24,
                              color: index == 0
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemChip extends StatelessWidget {
  const _ItemChip({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final meta = _BottomBarPreview._meta[id];
    final label = meta?.$1 ?? id;
    final icon = meta?.$2 ?? Icons.circle_outlined;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.surface.withValues(alpha: dark ? 0.6 : 0.8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.55)
                : (dark ? XyColors.darkBorder : XyColors.lightBorder),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
