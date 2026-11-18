import 'dart:async';

import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'player_sheet_morph.dart';

const xyPageTransitionDuration = Duration(milliseconds: 300);
const xyPageReverseTransitionDuration = Duration(milliseconds: 260);

/// 播放栏 ↔ 详情页形变转场：展开走 420ms，收起走 360ms（参考
/// CurrentMusicX PlayerSheetTransition.kt 的 PLAYER_SHEET_DURATION /
/// PLAYER_SHEET_CLOSE_DURATION）。正向与反向时长不再共用同一个值。
const xyPlayerSheetTransitionDuration = xyPlayerSheetOpenDuration;
const xyPlayerSheetReverseTransitionDuration = xyPlayerSheetCloseDuration;

/// 播放详情页转场进行中标记：详情页从屏幕底部滑入/收回期间，底下壳层
/// 页面的二级转场（跟随覆盖页动画）必须冻结——「页面从静态背景上滑过」
/// 要求壳层与播放栏完全静止，否则全局切换模式为平移/层叠时壳层会沿
/// 水平轴错向滑动（与竖直滑入混轴）。由 [xyPlayerSheetTransition] 按
/// 转场状态同步置位/复位，[xyPageTransition] 读取。
bool xySecondaryTransitionFrozen = false;

/// 页面切换模式的全局镜像。
///
/// 路由的 transitionsBuilder 无法访问 WidgetRef，由根组件（app.dart）
/// 在设置加载或变化时写入该值；每次新导航都会读取最新模式。
PageTransitionMode xyPageTransitionMode = PageTransitionMode.fade;

/// 当前播放详情页路由引用：路由构造即赋值（早于 install），供播放栏
/// 上滑跟手驱动转场值；路由 dispose 时清除。
XyPlayerSheetRoute<dynamic>? xyPlayerSheetRouteRef;

/// 形变转场全局标记自愈：路由已不在导航栈（[xyPlayerSheetRouteRef] 为空）
/// 却残留「转场中 / 已激活」标记时强制复位。
///
/// 「播放栏点开没展开、界面卡住」的成因：`/player` 路由对象已经构造并
/// 置位了 [xySheetRouteActive] / [xyPlayerSheetMorphing] /
/// [xyPlayerPageCoverReveal]，但这次 push 没有真正进入导航栈（被拒、
/// 交互竞态、导航器未就绪抛错）。路由不会 install，也就永远不会有
/// dispose 来复位——于是所有 [MiniPlayerBar] 实例永久停在隐藏态，
/// 壳层的转场冻结门（shell.dart 的 _ShellFreezeGate）按 morphing 永久
/// 冻结成快照，整页表现为「不动、点不动」。此时唯一可靠的复位时机就是
/// 这里：只要没有存活的形变路由，就把标记拉回静止态。
bool healPlayerSheetGlobals() {
  final route = xyPlayerSheetRouteRef;
  // 路由还在导航栈里正常运转：不动任何标记。
  if (route != null && route.isActive) return false;
  if (route != null) xyPlayerSheetRouteRef = null;
  var healed = false;
  if (xySheetRouteActive.value) {
    xySheetRouteActive.value = false;
    healed = true;
  }
  if (xyPlayerSheetMorphing.value) {
    xyPlayerSheetMorphing.value = false;
    healed = true;
  }
  if (xyPlayerSheetGestureDriving) {
    xyPlayerSheetGestureDriving = false;
    healed = true;
  }
  if (xySecondaryTransitionFrozen) {
    xySecondaryTransitionFrozen = false;
    healed = true;
  }
  if (xyPlayerPageCoverReveal.value != 1) {
    syncPlayerPageCoverReveal(1);
    healed = true;
  }
  return healed;
}

CurvedAnimation _xyCurve(Animation<double> parent) => CurvedAnimation(
  parent: parent,
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

/// 页面切换过渡入口：按设置中的切换模式分发。
///
/// 动画落定后（入场完成且未被新页面覆盖）直接裸返回页面本身：
/// 不包裹任何过渡层（Slide/Fade/遮罩），从结构上杜绝装饰层
/// 遮挡点击与滚动的可能。
Widget xyPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      final settled = animation.value >= 1 && secondaryAnimation.value <= 0;
      if (settled) return child!;
      // 播放详情页转场期间冻结本页的二级转场（壳层保持静止）。
      if (xySecondaryTransitionFrozen) return child!;
      // 过渡期间把页面内容圈成独立重绘边界：页面本体（长列表、毛玻璃、
      // 封面模糊、着色器）只需光栅化一次，动画每帧仅更新外层变换与不透明
      // 度，避免整页在 300ms 过渡里逐帧重绘造成切换掉帧。落定后不保留该
      // 边界（走上面的裸返回），不产生常驻图层。
      final page = RepaintBoundary(child: child!);
      switch (xyPageTransitionMode) {
        case PageTransitionMode.slide:
          return _XySlidePageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
        case PageTransitionMode.stack:
          return _XyStackPageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
        case PageTransitionMode.fade:
          return _XyFadePageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
      }
    },
  );
}

/// 平移：前后两页同步水平推移，边界始终相接。
/// 入场页左缘带过渡阴影、被覆盖页轻微压暗，落定后均不可见，
/// 避免透明页面在动画中产生“叠加”观感。
class _XySlidePageTransition extends StatelessWidget {
  const _XySlidePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return ClipRect(
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(incoming),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-1, 0),
          ).animate(covered),
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              // 入场页左缘阴影：动画进行中可见，落定后淡出。
              // IgnorePointer 确保装饰层永不参与命中测试，
              // 否则透明度为 0 时仍会吞掉整页点击。
              FadeTransition(
                opacity: ReverseAnimation(incoming),
                child: const IgnorePointer(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 24,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.black45, Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 被覆盖页压暗：跟随覆盖进度加深，最多 24%。
              // ColoredBox 对命中测试始终不透明，必须用 IgnorePointer
              // 隔离，否则动画落定后整页按钮都点不动。
              FadeTransition(
                opacity: covered.drive(Tween<double>(begin: 0, end: .24)),
                child: const IgnorePointer(
                  child: ColoredBox(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 层叠：入场页从右侧滑入并淡入，被覆盖页向左错开、轻微缩小并渐隐，
/// 两页在动画中前后交叠，落定后下层页完全隐藏。
class _XyStackPageTransition extends StatelessWidget {
  const _XyStackPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(incoming),
      child: FadeTransition(
        opacity: incoming,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-.3, 0),
          ).animate(covered),
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: .95).animate(covered),
            child: FadeTransition(
              opacity: ReverseAnimation(covered),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 淡入淡出：入场页渐显，被覆盖页渐隐，两页交叉淡化，
/// 落定后下层页完全消失。
class _XyFadePageTransition extends StatelessWidget {
  const _XyFadePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return FadeTransition(
      opacity: incoming,
      child: FadeTransition(opacity: ReverseAnimation(covered), child: child),
    );
  }
}

/// 播放详情页专属转场（光锥播放器 LightC 同款形变）：详情页面板从
/// 播放栏矩形连续生长到全屏（顶边全程跟手、圆角收平、封面连续变形、
/// 栏内容与页面内容交叉淡化），收起为完全倒序，与全局页面切换模式
/// 设置无关（底部弹出语义与迷你播放条「上滑打开」手势一致）。
///
/// 缺少形变起点（[xyPlayerSheetOrigin] 为 null，深链直达详情页等）
/// 时退回底部滑入兜底动画（[_playerSheetFallbackTransition]）。
/// 转场进行中置位 [xySecondaryTransitionFrozen] 冻结壳层二级转场，
/// 落定后复位；落定后裸返回页面本体，性能策略与 [xyPageTransition]
/// 相同。
Widget xyPlayerSheetTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      // 冻结标记与转场状态同步：前向/反向进行中冻结壳层，落定（含被
      // 上层页覆盖）后解除，不影响其它页面的正常转场。
      xySecondaryTransitionFrozen =
          animation.status == AnimationStatus.forward ||
          animation.status == AnimationStatus.reverse;
      // 背景降级标记同步（t 未落定即转场中）。必须在帧后置位：build 阶段
      // 直接写会同步通知监听者（详情页背景层）markNeedsBuild 而抛异常。
      // 展开时页面本体在 t≈0.55 才挂载，首帧读到的已是降级值；t=1 落定
      // 后一帧内恢复完整背景。
      _syncPlayerSheetMorphing(animation.value < 1);
      // 帧级终点自愈：收起已提交（_dismissing）且转场值已经到 0、却仍未
      // 被移除的路由，就在这里兜底 pop。收起补间的 dismissed/whenComplete
      // 任一环节丢帧都会让路由留在 overlay 里，morph 复刻层因此永久残留
      // （用户看到播放栏「已恢复」其实看到的是复刻栏，正文/迷你歌词不再
      // 恢复，整页点不动）。这里只排程、不在 build 内直接 pop。
      xyPlayerSheetRouteRef?.settleIfCollapsed(
        animation.value,
        animation.status,
      );
      // 落定（含被上层页覆盖）裸返回：t=1 时形变各层退化为页面本身。
      if (animation.value >= 1) {
        // 落定即详情页封面样式完全显现（飞行层已退场，裸返回后没有
        // 任何一层再提供封面视觉）。
        syncPlayerPageCoverReveal(1);
        return child!;
      }
      if (xyPlayerSheetOrigin == null) {
        // 无形变起点（深链直达、无播放栏封面可取等）走兜底滑入转场，
        // 全程没有飞行封面层提供封面视觉，详情页封面必须保持常显，
        // 否则转场中会出现封面空白。
        syncPlayerPageCoverReveal(1);
        return _playerSheetFallbackTransition(animation, child);
      }
      return XyPlayerSheetMorph(animation: animation, child: child);
    },
  );
}

/// 把「转场未落定」写入 [xyPlayerSheetMorphing]：值未变时零开销，值变化
/// 时推迟到帧末提交，避免 build 阶段同步通知监听者引发 markNeedsBuild
/// 异常（详情页背景层是 ValueListenableBuilder，收到通知会重建）。
void _syncPlayerSheetMorphing(bool morphing) {
  if (xyPlayerSheetMorphing.value == morphing) return;
  if (_pendingPlayerSheetMorphing == morphing) return;
  _pendingPlayerSheetMorphing = morphing;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_pendingPlayerSheetMorphing != morphing) return;
    _pendingPlayerSheetMorphing = null;
    if (xyPlayerSheetMorphing.value != morphing) {
      xyPlayerSheetMorphing.value = morphing;
      // 探针 raster 归因窗口随 morphing 状态同步（帧回调在 build 之外
      // 读取该标记，这里也是帧后提交，同步写安全）。
    }
  });
}

bool? _pendingPlayerSheetMorphing;

/// 兜底转场：全屏覆盖页从底部向上滑入/收回（5574 行为）。
Widget _playerSheetFallbackTransition(
  Animation<double> animation,
  Widget? child,
) {
  final curved = _xyCurve(animation);
  final t = curved.value;
  final raw = animation.value;
  final fadeT = animation.status == AnimationStatus.reverse
      ? const Interval(0, 0.45, curve: Curves.easeIn).transform(raw)
      : const Interval(0, 0.45, curve: Curves.easeOut).transform(raw);
  // 顶部圆角随进度长出再收平（中段峰值 24），静止时归零。
  final radius = 96.0 * t * (1 - t);
  return SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(curved),
    child: ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      clipBehavior: radius > 0.5 ? Clip.antiAlias : Clip.none,
      child: Opacity(
        opacity: fadeT,
        child: RepaintBoundary(child: child!),
      ),
    ),
  );
}

/// 播放详情页路由：暴露动画控制器的手势驱动接口，供播放栏上滑与详情
/// 页下滑实时驱动转场（子类内访问 @protected controller 是 Dart 允许的
/// 用法，对外只暴露下列公开成员）。
class XyPlayerSheetRoute<T> extends PageRouteBuilder<T> {
  XyPlayerSheetRoute({required super.settings, required WidgetBuilder builder})
    : super(
        transitionDuration: xyPlayerSheetTransitionDuration,
        reverseTransitionDuration: xyPlayerSheetReverseTransitionDuration,
        // 不透明关闭：形变面板为毛玻璃半透明，需要持续采样其下的壳层
        // 页面（转场中与落定后都是）；落定后详情页自身不透明盖满全屏。
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: xyPlayerSheetTransition,
      ) {
    xyPlayerSheetRouteRef = this;
    // 注意：其余全局转场标记（xySheetRouteActive / xyPlayerSheetMorphing /
    // xyPlayerPageCoverReveal）**不在这里置位**，统一挪到 install()。
    // 构造先于导航器接管执行，若这次 push 最终没有真正安装（导航器未就绪、
    // 交互竞态、被上层 push 抢占），标记会永久停在「转场中」，而路由没
    // install 就不会有 dispose 来复位——播放栏永久隐藏、壳层被快照永久
    // 冻结，表现为「点播放栏没反应、整页卡住」。
  }

  /// 手势写入的目标转场值：控制器未就绪（尚未 install）时暂存，
  /// install 后应用，保证 push 当帧不丢跟手进度。
  double? _dragTarget;

  /// 收起已提交（collapseAndPop 已调用或路由已 pop）：后续手势写入
  /// /回弹一律忽略，确保收起动画一路播到 0（dismissed）再移除路由，
  /// 不被中途 stop 造成半透明面板残留。
  bool _dismissing = false;

  /// 拖动写入停滞自愈计时器：正常跟手时 move 事件间隔 <100ms，此计时
  /// 器不断被重置；若停写超时（手指已被系统手势抢断、up/cancel 全部
  /// 丢失），面板无人驱动永久停在中间态 → 自动按收起收敛。
  /// 判定条件保守（面板在开区间 + 无补间动画在跑），正常「按住不动
  /// 观察」超过 1.2s 的场景在收起手势里实际不存在，误收可忽略。
  Timer? _dragStallTimer;

  /// 收起补间终点兜底计时器：动画时长 +120ms 仍没等到 dismissed / 补间
  /// 完成，就把转场值强制落到 0 并移除路由（详见 [_startCollapse]）。
  Timer? _popFallbackTimer;

  /// 帧级终点自愈的重入闸：同一帧里的多次 build 只排程一次回调
  /// （详见 [settleIfCollapsed]）。
  bool _settleGuard = false;

  /// 是否已经发起过移除本路由的请求：pop / removeRoute 只允许发一次。
  /// 必须拦住重复调用——第一次 `Navigator.pop()` 后本路由的 entry 已进入
  /// `pop` 状态（不再是 isPresent），第二次 pop 会落到下一层路由（壳层
  /// 页面）上，把用户带到错误的页面。
  bool _popIssued = false;

  /// 是否已提交收起（[collapseAndPop] 已调用或路由已 pop）。
  /// 形变层据此在收起阶段整层不接收指针，避免解析中的手势继续驱动
  /// 已被判死的转场。
  bool get isCollapsing => _dismissing;

  /// 拖动实时驱动：详情页下滑收起为 1 → 0，播放栏上滑展开为 0 → 1。
  /// 置位跟手标记（morph 层线性映射，不叠加缓动曲线），保证面板严格
  /// 跟随手指。
  set dragValue(double value) {
    // 收起已提交后忽略残留手势写入：防止 pop 后裸指针 Listener 仍调用
    // controller.stop() 抢断收起动画（stop 后 direction=dismiss 但 status
    // 停在 reverse 而非 dismissed，路由永不 dispose 造成半透明面板残留）。
    if (_dismissing || !isActive) return;
    _dragTarget = value.clamp(0.0, 1.0);
    xyPlayerSheetGestureDriving = true;
    // 探针：跟手期间剔除手势节奏伪影（见 probe onAnimFrame 注释）。
    final controller = this.controller;
    if (controller == null) return;
    if (controller.isAnimating) controller.stop();
    controller.value = _dragTarget!;
    // 拖动写入停滞自愈：刷新停滞计时器，停写超时且面板停在中间态
    // （无补间在跑）时自动收起，覆盖 up/cancel 被系统手势抢断丢失、
    // 松手判定整条未执行的路径。
    _dragStallTimer?.cancel();
    _dragStallTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_dismissing || !isActive) return;
      final c = this.controller;
      if (c == null || c.isAnimating) return;
      if (_dragTarget == null || _dragTarget! <= 0 || _dragTarget! >= 1) {
        return;
      }
      collapseAndPop();
    });
  }

  /// 松手回弹到全屏：时长按剩余距离等比缩短，避免短距回弹拖沓。
  void springBack() {
    // 收起已提交后禁止回弹：面板必须沿收起动画继续走完，避免
    // 残留手势把面板重新拉回全屏。
    if (_dismissing || !isActive) return;
    xyPlayerSheetGestureDriving = false;
    _dragStallTimer?.cancel();
    final controller = this.controller;
    if (controller == null) return;
    if (controller.isAnimating) controller.stop();
    final visual = controller.value.clamp(0.0, 1.0);
    if (visual <= 0 || visual >= 1) return;
    // 松手动画起点连续化：跟手阶段形态层按线性映射（t=raw），松手后
    // 按方向套缓动曲线。若直接以当前 raw 起步，easeOutCubic 会把中间
    // 值抬高（拖到 50% 松手回弹：easeOutCubic(0.5)=0.875，面板首帧
    // 上跳 37.5% 屏），即松手瞬间“卡一下”。把视觉位置反解回曲线
    // 坐标作为动画起点，再以线性驱动 raw，保证「跟手线性 → 动画曲线」
    // 切换瞬间视觉位置连续、速度不骤变；raw 驱动改用 Curves.linear，
    // 避免与形态层的 easeOutCubic 叠加成双重缓动（起点速度≈0 的顿挫）。
    final start = xySheetCurveInverse(xyPlayerSheetOpenCurve, visual);
    controller.value = start;
    unawaited(
      controller.animateTo(
        1.0,
        duration: Duration(
          milliseconds:
              (xyPlayerSheetTransitionDuration.inMilliseconds * (1 - start))
                  .round(),
        ),
        curve: Curves.linear,
      ),
    );
  }

  /// 松手收回：面板缩回播放栏矩形，动画完成后移除路由（此时转场值
  /// 已为 0，路由离场无视觉跳变）。
  void collapseAndPop() {
    // 收起提交后置位防重入：同一路由的后续手势/重复收起请求一律
    // 忽略，保证收起动画一路播到 0（dismissed）再移除。
    if (_dismissing || !isActive) return;
    _dismissing = true;
    _dragStallTimer?.cancel();
    xyPlayerSheetGestureDriving = false;
    final controller = this.controller;
    if (controller == null) {
      _popSelf();
      return;
    }
    if (controller.isAnimating) controller.stop();
    final visual = controller.value.clamp(0.0, 1.0);
    if (visual <= 0) {
      // 已经是收起终点：直接移除；若 pop 被吞掉，超时闸会再用
      // removeRoute 兜底（终点必达，不留残影）。
      _popSelf();
      _scheduleForceRemove();
      return;
    }
    if (visual >= 1) {
      // 未拖拽（单击收起）：整段收起动画，走收起的时长与缓动曲线
      // cubic-bezier(.3,0,.2,1)（与展开曲线(.2,0,0,1)成对）。
      _startCollapse(
        controller: controller,
        duration: Duration(
          milliseconds:
              (xyPlayerSheetReverseTransitionDuration.inMilliseconds * visual)
                  .round(),
        ),
        curve: xyPlayerSheetCloseCurve,
      );
      return;
    }
    // 松手动画起点连续化（同 springBack）：跟手阶段线性映射，松手后
    // 形态层按 easeInCubic 映射，若直接以当前 raw 起步会把中间值压扁
    // （拖到 50% 松手收起：easeInCubic(0.5)=0.125，面板首帧骤缩 37.5%
    // 屏），即松手瞬间“卡一下”。将视觉位置反解回曲线坐标作为动画
    // 起点，raw 用线性驱动，松手瞬间视觉位置连续、速度不骤变。
    final start = xySheetCurveInverse(xyPlayerSheetCloseCurve, visual);
    controller.value = start;
    _startCollapse(
      controller: controller,
      duration: Duration(
        milliseconds:
            (xyPlayerSheetReverseTransitionDuration.inMilliseconds * start)
                .round(),
      ),
      curve: Curves.linear,
    );
  }

  /// 启动收起补间，并加「终点必达双保险」。
  ///
  /// 原来只有 `whenComplete(_popSelf)` 一条出口：补间一旦被外部 stop、被
  /// 静音的 Ticker 拖住、或最后一帧因主 isolate 过载没跑到，动画就永远
  /// 停在 dismissed 之前——而 `_dismissing` 已置位，再没有任何路径会尝试
  /// 移除路由，morph 层于是永久留在 overlay 里（画面冻结在收起前一帧）。
  /// 这里三条出口并行，任一条先到即收口：
  /// 1) controller 的 dismissed 状态监听（正常终点，最早触发）；
  /// 2) `whenComplete`（补间正常结束）；
  /// 3) 硬超时（动画时长 +120ms，覆盖补间停摆/被吞的极端情况）。
  void _startCollapse({
    required AnimationController controller,
    required Duration duration,
    required Curve curve,
  }) {
    _popFallbackTimer?.cancel();
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.dismissed) return;
      _clearCollapseHooks(controller, onStatus);
      _popSelf();
    }

    controller.addStatusListener(onStatus);
    _popFallbackTimer = Timer(duration + const Duration(milliseconds: 120), () {
      _clearCollapseHooks(controller, onStatus);
      if (!isActive) {
        // 路由已离开导航栈却仍有残留标记：就地自愈，避免壳层被永久快照
        // 冻结（整页画面停住、点不动）。
        healPlayerSheetGlobals();
        return;
      }
      // 超时：不看动画当前值，直接按收起终点落定，再移除路由。
      if (controller.isAnimating) controller.stop();
      controller.value = 0;
      _popSelf();
      _scheduleForceRemove();
    });
    unawaited(
      controller.animateTo(0.0, duration: duration, curve: curve).whenComplete(
        () {
          _clearCollapseHooks(controller, onStatus);
          _popSelf();
        },
      ),
    );
  }

  /// 拆掉收起补间的两条监听（状态监听 + 超时计时器），幂等。
  void _clearCollapseHooks(
    AnimationController controller,
    AnimationStatusListener listener,
  ) {
    controller.removeStatusListener(listener);
    _popFallbackTimer?.cancel();
    _popFallbackTimer = null;
  }

  /// 最后一道闸：pop 已发出但路由仍在栈内（pop 被吞、导航器处于过渡态、
  /// route 迟迟收不到 dismissed）时，用 [Navigator.removeRoute] 按对象
  /// 移除——它绝不会误弹下一层页面，保证 morph 残留层一定被摘掉。
  /// 刻意用 Timer 而非帧后回调：这条路径就是为「帧已经跑不动」准备的。
  void _scheduleForceRemove() {
    Timer(const Duration(milliseconds: 80), () {
      if (!isActive) return;
      final navigator = this.navigator;
      if (navigator == null) {
        healPlayerSheetGlobals();
        return;
      }
      navigator.removeRoute(this);
    });
  }

  /// 帧级终点自愈（由 [xyPlayerSheetTransition] 的 builder 每帧调用）：
  /// 收起已提交、转场值已在 0、且不是展开补间在跑时，帧后强制收口
  /// （停动画、落定到 0、移除路由）。
  ///
  /// 必须校验 `_dismissing`：否则正常展开动画起步时（value≈0、status 为
  /// idle/forward 的过渡帧）会被误判成「收起到底了」而误弹路由。
  void settleIfCollapsed(double value, AnimationStatus status) {
    if (!_dismissing || _settleGuard) return;
    if (value > .001) return;
    if (status == AnimationStatus.forward) return;
    if (!isActive) return;
    _settleGuard = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleGuard = false;
      if (!isActive) return;
      final controller = this.controller;
      if (controller != null && controller.isAnimating) controller.stop();
      _popSelf();
    });
  }

  void _popSelf() {
    _popFallbackTimer?.cancel();
    _popFallbackTimer = null;
    // 只允许发起一次移除请求（见 [_popIssued] 注释）。
    if (_popIssued) return;
    final navigator = this.navigator;
    if (navigator == null || !isActive) {
      // 路由已经不在导航栈里，却还留着「转场中/已激活」标记：就地自愈，
      // 否则壳层按 morphing 永久快照冻结——正是用户看到的「整页冻住、
      // 播放栏歌名歌手不恢复、按返回键才活」。
      healPlayerSheetGlobals();
      return;
    }
    _popIssued = true;
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      // 栈里只剩自己（canPop 为假）时 pop 无效，直接按对象移除。
      navigator.removeRoute(this);
    }
  }

  @override
  void install() {
    super.install();
    // 转场全局标记：进入导航栈（install 由 Navigator.push 同步调用、
    // 早于首帧 build）才置位，与原来的构造器置位时序等价，但 scatter
    // 路径不会漏：push 没成功 = 没 install = 不留脏标记。
    // 1) 转场期间隐藏所有 MiniPlayerBar 实例本体（morph 层复刻提供面板
    //    视觉），收起动画结束（dispose）后恢复。
    xySheetRouteActive.value = true;
    // 2) 首帧就把「转场中」置位：morphing 常规同步走 postFrame
    //    （见 _syncPlayerSheetMorphing），首帧空档会让壳层停画判定
    //    （shell.dart 的 P0-4）误判一帧「已落定」，把展开首帧的壳层
    //    Offstage 掉（morph 层 backdrop 下无内容，可能闪一帧深色）。
    xyPlayerSheetMorphing.value = true;
    // 3) 转场起步即隐藏详情页真实封面：封面视觉全程由形变层的迷你封面
    //    飞行层提供，详情页封面样式（黑胶盘 / 直角沉浸 / 圆角方图及其
    //    唱臂、反光装饰）要等飞到位才显现，否则首帧会闪一下封面。
    xyPlayerPageCoverReveal.value = 0;
    // install 创建控制器后立即应用暂存的拖动值，didPush 从该值续播。
    final controller = this.controller;
    // 探针：动画帧回调间隔与掉帧统计（覆盖跟手写值与 animateTo 动画帧）。
    final value = _dragTarget;
    if (controller != null && value != null && value > 0) {
      controller.value = value;
    }
  }

  @override
  void dispose() {
    _dragStallTimer?.cancel();
    // 终点兜底计时器随路由销毁一并取消，避免回调在已 dispose 的
    // controller 上写值。
    _popFallbackTimer?.cancel();
    _popFallbackTimer = null;
    // 探针：与 install 配对的动画帧监听移除。
    if (identical(xyPlayerSheetRouteRef, this)) {
      xyPlayerSheetRouteRef = null;
    }
    xySheetRouteActive.value = false;
    // 兜底复位背景降级标记：正常路径由 t=1 落定复位，这里覆盖收起动画
    // 播完（dismissed）/路由被外部直接移除等路径，避免详情页背景永久
    // 停在轻量版本。
    _syncPlayerSheetMorphing(false);
    // 兜底复位详情页封面显现度：正常路径由落定写 1，这里覆盖收起动画
    // 播完（dismissed）/路由被外部直接移除等路径——否则页面若被复用或
    // 下次直接进入详情页（深链、兜底转场），封面会永久停在隐藏态。
    syncPlayerPageCoverReveal(1);
    // 探针 raster 归因窗口同步关闭（与 install 置位配对；postFrame 路径
    // 正常也会写 false，这里是路由被外部直接移除时的兜底）。
    // 兜底复位冻结标记：正常路径由转场落定复位，这里覆盖转场被异常
    // 中断（路由被外部直接移除等）的情况，避免壳层二级转场被永久冻结。
    xySecondaryTransitionFrozen = false;
    // 同步复位跟手标记，防止下一轮正常补间动画被误判为手势驱动。
    xyPlayerSheetGestureDriving = false;
    super.dispose();
  }
}

class XyAnimatedPageRoute<T> extends PageRouteBuilder<T> {
  XyAnimatedPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: xyPageTransitionDuration,
        reverseTransitionDuration: xyPageReverseTransitionDuration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: xyPageTransition,
      );
}
