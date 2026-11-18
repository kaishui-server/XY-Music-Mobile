import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'animated_page_route.dart';

/// 底栏/侧栏可见顺序下的分支下标序列。
///
/// 分支下标顺序（首页/音乐库/音效/设置）与用户拖动时「左右相邻页」的
/// 语义并不一致，且底栏顺序可自定义，因此由 AppShell 每次导航时按可见
/// 顺序写入，分支容器据此决定拖动方向的目标页。
List<int> branchSwipeOrder = const <int>[];

/// 横向滑动切页是否可用。
///
/// 由 AppShell 写入：底栏可见、可见目的地不少于两个、且当前停留在
/// 一级页面根部时可用；进入二级页（歌单详情等）后让位给页面自身手势。
bool branchSwipeEnabled = false;

/// 底栏一级分页（分支）切换是否正在进行。
///
/// 【性能】切换期间前后两页在全屏尺寸上交叉淡化，底栏那颗
/// `BackdropFilter.grouped`（sigma 12）每帧都要对变化中的背景重新采样一次
/// 整条栏宽的区域，是 raster 线程的额外固定开支。这里把切换状态广播给底栏，
/// 切换期间临时摘掉毛玻璃、落定后立刻恢复，避免「淡化 + 毛玻璃重采样」
/// 同时压在同一批帧上。
final ValueNotifier<bool> xyBranchSwitchActive = ValueNotifier<bool>(false);

/// 更新横滑切页的可见顺序与可用性。
///
/// 只在顺序真正变化时重建列表，避免每帧导航重建都产生新实例。
void updateBranchSwipe({required bool enabled, required List<int> order}) {
  branchSwipeEnabled = enabled;
  final current = branchSwipeOrder;
  var same = current.length == order.length;
  if (same) {
    for (var index = 0; index < order.length; index++) {
      if (current[index] != order[index]) {
        same = false;
        break;
      }
    }
  }
  if (!same) branchSwipeOrder = List<int>.unmodifiable(order);
}

/// 把可见目的地顺序（底栏在前、其余按侧栏顺序）映射成分支下标序列。
///
/// 可见目的地可能指向分支内的子路由（「探索」/home/explore、「听歌识曲」
/// /home/recognize、「插件管理」/settings/plugins、「任务管理」
/// /settings/tasks），也可能根本不属于任何分支（「账号」/account 由根导航
/// 承载，无法用分支切换表达）。因此不能拿路径做全等比较，必须按「最长
/// 分支根前缀」归属：否则子路由入口会被整条丢弃，账号页还会被错算进设置
/// 分支，导致可切换项不足两个而横滑整体失效。
///
/// 当前分支不在可见目的地里时（底栏没放首页、停在「首页」分支根等）补到
/// 序列最前，否则容器无法定位当前位置，拖动会全无反应。
List<int> branchSwipeOrderFromPaths({
  required List<String> visiblePaths,
  required List<String?> branchPaths,
  required int currentIndex,
}) {
  int? branchOf(String path) {
    final normalized = path.split('?').first;
    if (normalized.isEmpty) return null;
    int? best;
    for (var index = 0; index < branchPaths.length; index++) {
      final root = branchPaths[index];
      if (root == null || root.isEmpty) continue;
      if (!(normalized == root || normalized.startsWith('$root/'))) continue;
      if (best == null || branchPaths[best]!.length < root.length) {
        best = index;
      }
    }
    return best;
  }

  final order = <int>[];
  for (final path in visiblePaths) {
    final index = branchOf(path);
    if (index == null || order.contains(index)) continue;
    order.add(index);
  }
  if (currentIndex >= 0 &&
      currentIndex < branchPaths.length &&
      !order.contains(currentIndex)) {
    order.insert(0, currentIndex);
  }
  return order;
}

/// 一级页面分支容器。
///
/// 切换效果跟随设置中的页面切换模式（xyPageTransitionMode），与路由
/// 过渡保持同一风格；所有非活动分支仍保留在树中，因此滚动位置、
/// Tab 状态和各页面 Navigator 都不会丢失。切换方向由路由层按用户
/// 可见的目的地顺序（底栏/侧栏）提供，而非分支下标差。
///
/// 除点击底栏触发的过渡外，还支持手指横向拖动跟手切页：拖动过程中
/// 当前页与目标页按手指位移实时平移（不经动画控制器），松手后按位移
/// 进度与甩动速度决定「切过去」还是「弹回」，全程可随时反向。
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    this.direction,
    this.onBranchSelected,
  });

  final int currentIndex;
  final List<Widget> children;

  /// 分支切换方向：+1 新页从右侧进入，-1 从左侧进入。null 时退回
  /// 分支下标差推断。
  final int? direction;

  /// 横滑跟手结束后提交的分支下标。由路由层决定是否采纳（通常直接
  /// 调 StatefulNavigationShell.goBranch）。
  final ValueChanged<int>? onBranchSelected;

  @override
  State<AnimatedBranchContainer> createState() =>
      _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<AnimatedBranchContainer>
    with TickerProviderStateMixin {
  late final AnimationController _controller;

  /// 缓动曲线：**必须**只建一次。
  ///
  /// `CurvedAnimation` 的构造函数会向 parent 注册 status listener
  /// （用于翻转 curve direction），而它自己从不摘除。旧实现把它写在
  /// `build()` 里，等于每次重建都往 controller 上挂一个新 listener：
  /// 一次 280ms 切换在 120Hz 上重建约 34 次，就永久留下 34 个监听器，
  /// 且随每次切页线性累积——久播/久用后 controller 单次 notify 要遍历
  /// 上千个闭包，正是「越用越卡、切页单帧 190~235ms」的嫌疑源之一。
  /// 提到 initState 建一次、dispose 显式释放后，行为与曲线完全不变。
  late final CurvedAnimation _movement;

  /// 松手后的收尾动画（把剩余行程补完），与点击切页的 _controller 分离，
  /// 避免跟手进度和过渡进度互相覆盖。
  late final AnimationController _settleController;

  int? _previousIndex;
  int _direction = 1;

  /// 跟手横滑：当前横向位移，单位为「页宽」，与手指同向。
  double _swipe = 0;

  /// 本次拖动的目标侧：+1 目标在左侧（去上一页），-1 目标在右侧（去下一页）。
  int _swipeSign = 0;

  /// 跟手展示的目标分支下标；非空即处于拖动/收尾过程。
  int? _swipeTarget;

  /// 邻居页预热：手指开始拖动时先把左右相邻分支渲染在屏外，使其首帧
  /// 构建与光栅化提前完成，真正滑入时不再掉帧。
  bool _warm = false;

  double _settleFrom = 0;
  double _settleTo = 0;
  int? _settleCommitIndex;
  int? _pendingCommitIndex;

  double _width = 1;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          // 【性能】切换时长由 280ms 压到 200ms：淡化期整屏合成是 raster
          // 侧最贵的部分，缩短时长即按比例缩短这段高开销窗口；曲线不变，
          // 观感仍是「快起缓收」。
          duration: const Duration(milliseconds: 200),
          value: 1,
        )..addStatusListener((status) {
          if (status.isAnimating) return;
          // 过渡结束（完成或被中断）：恢复底栏毛玻璃。
          xyBranchSwitchActive.value = false;
          if (status == AnimationStatus.completed && _previousIndex != null) {
            setState(() => _previousIndex = null);
          }
        });
    _movement = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_onSettleTick);
    _settleController.addStatusListener(_onSettleStatus);
  }

  /// 【性能】统一收放底栏毛玻璃：相同值不重复写入，避免无意义通知。
  void _setSwitching(bool value) {
    if (xyBranchSwitchActive.value == value) return;
    xyBranchSwitchActive.value = value;
  }

  @override
  void didUpdateWidget(AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex == widget.currentIndex) {
      // 路由没有采纳横滑提交（分支未变）：清掉挂起的提交并恢复毛玻璃，
      // 避免拖动被打断后底栏一直处于「无毛玻璃」状态。
      if (_pendingCommitIndex != null) {
        _pendingCommitIndex = null;
        _setSwitching(false);
      }
      return;
    }
    // 这次切换是横滑跟手「滑到位」后提交的：视觉上目标页已经停在最终
    // 位置，不能再播一遍内置过渡，否则会二次滑动。直接清空跟手状态，
    // 由本次 build 以常规层渲染。
    if (_pendingCommitIndex == widget.currentIndex) {
      _pendingCommitIndex = null;
      _previousIndex = null;
      _swipe = 0;
      _swipeSign = 0;
      _swipeTarget = null;
      _warm = false;
      // 跟手期已摘掉毛玻璃，此时没有补间可跑，直接恢复。
      _setSwitching(false);
      return;
    }
    _pendingCommitIndex = null;
    _abortSwipe();
    _previousIndex = oldWidget.currentIndex;
    _direction =
        widget.direction ??
        (widget.currentIndex > oldWidget.currentIndex ? 1 : -1);
    // 【性能】切换期间通知底栏摘掉毛玻璃（见 [xyBranchSwitchActive]）。
    xyBranchSwitchActive.value = true;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    // 容器被销毁时兜底恢复底栏毛玻璃，避免切换中途被移除而永久关掉模糊。
    xyBranchSwitchActive.value = false;
    // 先释放曲线再释放 controller：CurvedAnimation.dispose 会去摘除它
    // 注册在 parent 上的 status listener。
    _movement.dispose();
    _controller.dispose();
    _settleController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // 跟手横滑
  // ---------------------------------------------------------------------

  int? _neighbor(int step) {
    final order = branchSwipeOrder;
    if (order.length < 2) return null;
    final position = order.indexOf(widget.currentIndex);
    if (position < 0) return null;
    final target = position + step;
    if (target < 0 || target >= order.length) return null;
    return order[target];
  }

  bool _canAcceptPointer(PointerDownEvent event) {
    if (!branchSwipeEnabled || widget.children.length < 2) return false;
    final previous = _neighbor(-1);
    final next = _neighbor(1);
    if (previous == null && next == null) return false;
    // 屏缘起手让给系统/抽屉手势：没有上一页时，左缘右滑不抢；没有
    // 下一页时，右缘左滑不抢。
    final width = _width <= 0 ? 1.0 : _width;
    final edge = width * 0.06;
    if (previous == null && event.position.dx < edge) return false;
    if (next == null && event.position.dx > width - edge) return false;
    return true;
  }

  void _handleStart(DragStartDetails details) {
    // 上一次提交可能还在等路由回写，先清干净再开始新的拖动。
    _abortSwipe();
    if (_controller.isAnimating) {
      _controller.stop();
      _controller.value = 1;
    }
    _warmNeighbors();
  }

  /// 手指刚有横向意图时先把左右相邻页布局好（屏外），accept 之后的首帧
  /// 就只剩位移，不会因为首次构建整页而掉帧。
  void _warmNeighbors() {
    if (_warm) return;
    if (_neighbor(-1) == null && _neighbor(1) == null) return;
    setState(() => _warm = true);
  }

  void _coolNeighbors() {
    if (_swipeTarget != null) return;
    if (!_warm) return;
    setState(() => _warm = false);
  }

  void _handleUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta == 0) return;
    var sign = _swipeSign;
    if (_swipeTarget == null) {
      sign = delta > 0 ? 1 : -1;
      final target = _neighbor(sign > 0 ? -1 : 1);
      if (target == null) return;
      setState(() {
        _swipeSign = sign;
        _swipeTarget = target;
      });
      // 【性能】跟手平移期间两页同时在屏，底栏毛玻璃会逐帧重采样背景，
      // 一并摘掉，松手落定后再恢复。
      _setSwitching(true);
      _swipe = 0;
    }
    final width = _width <= 0 ? 1.0 : _width;
    var next = _swipe + delta / width;
    // 拖回起点后继续反向：换到另一侧的目标页继续跟手，而不是把两页
    // 一起往反方向拖。
    if (next * sign < -0.02) {
      final other = _neighbor(sign > 0 ? 1 : -1);
      if (other == null) {
        next = 0;
      } else {
        sign = -sign;
        setState(() {
          _swipeSign = sign;
          _swipeTarget = other;
        });
        _swipe = 0;
        next = delta / width;
      }
    }
    // 越界阻尼：走满一页后继续拖只轻微跟手，形成橡皮筋手感。
    final abs = next.abs();
    if (abs > 1) {
      next = next.sign * (1 + (abs - 1) * 0.16);
      if (next.abs() > 1.14) next = next.sign * 1.14;
    }
    setState(() => _swipe = next);
  }

  void _handleEnd(DragEndDetails details) {
    final target = _swipeTarget;
    final sign = _swipeSign;
    if (target == null || sign == 0) {
      if (_warm) setState(() => _warm = false);
      return;
    }
    final width = _width <= 0 ? 1.0 : _width;
    final progress = _swipe * sign; // 朝目标前进的进度，单位页
    final velocity = (details.primaryVelocity ?? 0) * sign / width; // 页/秒
    final commit =
        progress > 0.34 ||
        velocity > 0.85 ||
        (progress > 0.12 && velocity > 0.35);
    _runSettle(commit ? sign.toDouble() : 0.0, commit ? target : null);
  }

  void _handleCancel() {
    // 已被其它手势抢走：跟手中途取消要回弹，不能停在两页之间。
    if (_swipeTarget != null) {
      _runSettle(0, null);
      return;
    }
    _coolNeighbors();
  }

  void _runSettle(double to, int? commitIndex) {
    _settleFrom = _swipe;
    _settleTo = to;
    _settleCommitIndex = commitIndex;
    final distance = (to - _swipe).abs();
    _settleController.duration = Duration(
      milliseconds: (130 + distance * 150).round(),
    );
    _settleController.forward(from: 0);
  }

  void _onSettleTick() {
    final eased = Curves.easeOutCubic.transform(_settleController.value);
    final next = _settleFrom + (_settleTo - _settleFrom) * eased;
    if ((next - _swipe).abs() < 0.0005) return;
    setState(() => _swipe = next);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final commit = _settleCommitIndex;
    _settleCommitIndex = null;
    if (commit == null) {
      setState(() {
        _swipe = 0;
        _swipeSign = 0;
        _swipeTarget = null;
        _warm = false;
      });
      // 回弹落定，跟手结束：恢复底栏毛玻璃。
      _setSwitching(false);
      return;
    }
    // 目标页此时已经停在最终位置，交给路由提交分支切换；跟手状态等到
    // didUpdateWidget 里 currentIndex 变化后再清，避免中间帧回跳。
    _pendingCommitIndex = commit;
    widget.onBranchSelected?.call(commit);
  }

  void _abortSwipe() {
    if (_settleController.isAnimating) _settleController.stop();
    _settleCommitIndex = null;
    _pendingCommitIndex = null;
    // 【性能】跟手被打断时同步恢复底栏毛玻璃，避免状态残留。
    _setSwitching(false);
    if (_swipe == 0 && _swipeSign == 0 && _swipeTarget == null && !_warm) {
      return;
    }
    setState(() {
      _swipe = 0;
      _swipeSign = 0;
      _swipeTarget = null;
      _warm = false;
    });
  }

  // ---------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    _width = media?.size.width ?? _width;
    final target = _swipeTarget;
    final swiping = target != null && target != widget.currentIndex;

    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _BranchSwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_BranchSwipeRecognizer>(
              () => _BranchSwipeRecognizer(
                canAccept: _canAcceptPointer,
                onEngage: _warmNeighbors,
                onRelease: _coolNeighbors,
              ),
              (recognizer) {
                recognizer
                  ..dragStartBehavior = DragStartBehavior.start
                  ..onCancel = _handleCancel
                  ..onStart = _handleStart
                  ..onUpdate = _handleUpdate
                  ..onEnd = _handleEnd;
              },
            ),
      },
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (var index = 0; index < widget.children.length; index++)
              swiping
                  ? _swipeLayer(index, target)
                  : _branchLayer(index, _movement),
          ],
        ),
      ),
    );
  }

  /// 跟手层：当前页与目标页按手指位移实时平移，其余分支完全移出树。
  Widget _swipeLayer(int index, int target) {
    final active = index == widget.currentIndex;
    final isTarget = index == target;
    final visible = active || isTarget;
    final width = _width <= 0 ? 1.0 : _width;
    final offset = active
        ? _swipe * width
        : (_swipe - _swipeSign) * width;
    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !active,
        child: Transform.translate(
          offset: Offset(offset, 0),
          child: RepaintBoundary(child: widget.children[index]),
        ),
      ),
    );
  }

  Widget _branchLayer(int index, Animation<double> movement) {
    final active = index == widget.currentIndex;
    final outgoing = index == _previousIndex;
    // 【性能】离场页在过渡期等价于「先快照再淡化」：它此刻只是一张正在
    // 淡出的静态画面，若内部进度条/歌词等 ticker 继续跑，外层
    // RepaintBoundary 的缓存每帧失效，等于两页同时重录整屏（raster 尖峰
    // 的主要来源）。冻结它的动画时钟后，合成器直接复用已录好的图层，
    // 只做透明度混合；200ms 后该页退出，恢复时钟不影响任何状态。
    final freezing = outgoing && _controller.isAnimating;
    var visible = active || outgoing;
    var offset = 0.0;
    var warming = false;
    if (!visible && _warm) {
      final width = _width <= 0 ? 1.0 : _width;
      if (index == _neighbor(-1)) {
        visible = true;
        warming = true;
        offset = -width;
      } else if (index == _neighbor(1)) {
        visible = true;
        warming = true;
        offset = width;
      }
    }

    Widget layer = _modeTransition(
      movement,
      active,
      RepaintBoundary(child: widget.children[index]),
    );
    if (offset != 0) {
      layer = Transform.translate(offset: Offset(offset, 0), child: layer);
    }

    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !active,
        // 纯预热的相邻页只做布局，不驱动其内部动画时钟；离场页在过渡期
        // 冻结时钟以复用图层缓存（见上）。
        child: TickerMode(enabled: !warming && !freezing, child: layer),
      ),
    );
  }

  /// 按设置中的页面切换模式分发底栏分支过渡。
  Widget _modeTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    switch (xyPageTransitionMode) {
      case PageTransitionMode.slide:
        final begin = active ? Offset(_direction.toDouble(), 0) : Offset.zero;
        final end = active ? Offset.zero : Offset(-_direction.toDouble(), 0);
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: end).animate(movement),
          child: child,
        );
      case PageTransitionMode.stack:
        return _stackTransition(movement, active, child);
      case PageTransitionMode.fade:
        return _fadeTransition(movement, active, child);
    }
  }

  /// 层叠：入场页从切换方向滑入并渐显，离场页反向错开、轻微缩小并渐隐。
  Widget _stackTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    if (active) {
      return SlideTransition(
        position:
            Tween<Offset>(
              begin: Offset(_direction.toDouble(), 0),
              end: Offset.zero,
            ).animate(movement),
        child: FadeTransition(opacity: movement, child: child),
      );
    }
    return SlideTransition(
      position:
          Tween<Offset>(
            begin: Offset.zero,
            end: Offset(-_direction * .3, 0),
          ).animate(movement),
      child: ScaleTransition(
        scale: Tween<double>(begin: 1, end: .95).animate(movement),
        child: FadeTransition(opacity: ReverseAnimation(movement), child: child),
      ),
    );
  }

  /// 淡入淡出：两页交叉淡化。
  Widget _fadeTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    return FadeTransition(
      opacity: active ? movement : ReverseAnimation(movement),
      child: child,
    );
  }
}

/// 只在允许时接管指针的横向拖动识别器。
///
/// 在 `addAllowedPointer` 阶段就决定是否入场：不满足条件（无相邻页、
/// 屏缘让位等）时直接不参与手势竞技场，页面自身的横向手势与抽屉边缘
/// 手势仍按原样工作。
class _BranchSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _BranchSwipeRecognizer({
    required this.canAccept,
    required this.onEngage,
    required this.onRelease,
  }) : super(debugOwner: 'AnimatedBranchContainer');

  final bool Function(PointerDownEvent event) canAccept;
  final VoidCallback onEngage;
  final VoidCallback onRelease;

  bool _engaged = false;
  double _travel = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!canAccept(event)) return;
    _engaged = false;
    _travel = 0;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    // 比 accept 阈值（touch slop）更早一步预热相邻页，给首帧留出布局时间。
    if (!_engaged && event is PointerMoveEvent) {
      _travel += event.delta.dx.abs();
      if (_travel > 8) {
        _engaged = true;
        onEngage();
      }
    }
    super.handleEvent(event);
  }

  @override
  void rejectGesture(int pointer) {
    onRelease();
    super.rejectGesture(pointer);
  }
}
