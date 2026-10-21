// visualizer_page.dart — 全屏音乐可视化页（5533 新增）。
//
// 复刻 sonic-topography 的核心形态：黑底粒子场景（地形/云海、星云两形态
// 可切换）+ 左侧逐行歌词 + 底部毛玻璃播放条 + 左侧竖排形态/面板图标栏 +
// 右侧设置抽屉（脉冲触发 / 主题颜色 / 音频检测）。
//
// 数据链：Android VisualizerBridge（输出混音 FFT，~20Hz）→
// VisualizerSource（64 段对数频段 + 帧间平滑）→ BeatDetector（低频窗口
// 谱通量节拍检测，移植 beatDetector.ts/kickEnvelope.ts）→ CustomPainter。
//
// 性能：场景渲染走 Ticker + repaint 通知器，歌词/进度条各自独立 watch，
// 设置变更不触发场景重建。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/player/beat_detector.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/visualizer_source.dart';
import '../../src/lyrics/lyrics_models.dart';
import 'visualizer_scenes.dart';
import 'visualizer_settings.dart';

/// 歌词偏移存取 key（与播放页共用同一份配置）。
const String _lyricsOffsetsKey = 'playerLyricsOffsetsTenthsV1';

enum _DrawerSection { none, pulse, theme, detect }

class VisualizerPage extends ConsumerStatefulWidget {
  const VisualizerPage({super.key});

  @override
  ConsumerState<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends ConsumerState<VisualizerPage>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  double _time = 0;

  // 节拍链路状态。
  BeatDetectorState _beatState = createBeatDetectorState();
  double _kickDeform = 0;
  double _deformTarget = 0;
  bool _pendingOnset = false;
  double _lastEnvelope = 0;
  List<double> _displayBands = List.filled(kVisBandCount, 0);
  // 数据源状态。
  bool _sourceReady = false;
  bool _sourceFailed = false;

  // UI 状态。
  _DrawerSection _drawer = _DrawerSection.none;
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);
  int _lyricsOffsetTenths = 0;
  String? _offsetLoadedFor;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    unawaited(_bootSource());
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _frameTick.dispose();
    unawaited(VisualizerSource.instance.stop());
    super.dispose();
  }

  Future<void> _bootSource() async {
    final ok = await VisualizerSource.instance.start();
    if (!mounted) return;
    setState(() {
      _sourceReady = ok;
      _sourceFailed = !ok;
    });
  }

  Future<void> _retrySource() async {
    setState(() => _sourceFailed = false);
    await _bootSource();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastElapsed == Duration.zero
        ? 1 / 60
        : (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _time += dt;

    final settings = ref.read(visualizerSettingsProvider);
    final src = VisualizerSource.instance;

    if (_sourceReady) {
      final gain = (settings.detectLevel / 100).clamp(0.0, 2.0);
      final smoothed = src.stepSmoothed(dt);
      for (int i = 0; i < kVisBandCount; i++) {
        _displayBands[i] = math.min(1.0, smoothed[i] * gain);
      }
    } else {
      // 无频谱数据（权限被拒/启动失败）时用怠速呼吸动画保持画面生命感。
      for (int i = 0; i < kVisBandCount; i++) {
        final w = i / kVisBandCount;
        _displayBands[i] = 0.08 +
            0.10 * (0.5 + 0.5 * math.sin(_time * 1.1 + w * 9)) *
                (1 - w * 0.7);
      }
    }

    // —— 节拍检测（脉冲触发）——
    if (settings.pulseEnabled && settings.autoPulse) {
      final start = settings.bandStart.clamp(0, kVisBandCount - 2);
      final end = settings.bandEnd.clamp(start + 1, kVisBandCount - 1);
      final List<double> windowBands = settings.pulseMode == PulseMode.advanced
          ? _displayBands.sublist(start, math.min(end + 1, start + 8))
          : _displayBands.sublist(0, 8);
      final out = stepBeatDetector(
        state: _beatState,
        windowBands: windowBands,
        deltaSeconds: dt,
        sensitivity: settings.sensitivity,
      );
      _beatState = out.state;
      _pendingOnset = out.kickOnset;
      _lastEnvelope = out.kickEnvelope;
    } else {
      _pendingOnset = false;
      _lastEnvelope = 0;
    }

    // —— 地形形变（节拍时长控制衰减速率）——
    const maxDeform = 0.75;
    final speed = 10.0 / math.max(0.5, settings.beatDuration);
    if (_pendingOnset) {
      _deformTarget = math.max(_deformTarget, maxDeform);
      _pendingOnset = false;
    }
    _deformTarget = math.max(0, _deformTarget - _deformTarget * 10 * speed * dt);
    _kickDeform += (_deformTarget - _kickDeform) *
        (1 - math.exp(-18 * speed * dt));

    _frameTick.value++;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(visualizerSettingsProvider);
    final player = ref.watch(playerProvider);
    final current = player.current;

    // 歌曲切换时重载歌词偏移。
    final songPath = current?.path ?? '';
    if (songPath.isNotEmpty && _offsetLoadedFor != songPath) {
      _offsetLoadedFor = songPath;
      unawaited(_loadLyricsOffset(songPath));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 场景层（Ticker 驱动，不随 riverpod 重建）。
            RepaintBoundary(
              child: CustomPaint(
                painter: settings.form == VisualizerForm.terrain
                    ? TerrainScenePainter(_sceneData(settings))
                    : NebulaScenePainter(_sceneData(settings)),
                isComplex: true,
                willChange: true,
              ),
            ),
            // 歌词覆盖层。
            Positioned(
              left: 68,
              right: 24,
              top: 0,
              bottom: 132,
              child: _LyricsOverlay(offsetTenths: _lyricsOffsetTenths),
            ),
            // 左上返回 + 左侧图标栏。
            Positioned(
              left: 10,
              top: 46,
              child: _Rail(
                activeDrawer: _drawer,
                form: settings.form,
                theme: settings.theme,
                onSelectDrawer: (s) => setState(() {
                  _drawer = _drawer == s ? _DrawerSection.none : s;
                }),
                onSelectForm: (f) => ref
                    .read(visualizerSettingsProvider.notifier)
                    .update((s) => s.copyWith(form: f)),
              ),
            ),
            // 底部毛玻璃播放条。
            Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: _GlassPlayBar(
                songPath: songPath,
                title: current?.title ?? '未在播放',
              ),
            ),
            // 右侧设置抽屉。
            _SettingsDrawer(
              section: _drawer,
              onClose: () => setState(() => _drawer = _DrawerSection.none),
            ),
            // 数据源失败提示（居中，短暂显示）。
            if (_sourceFailed)
              Positioned(
                left: 68,
                bottom: 150,
                child: _SourceFailHint(onRetry: _retrySource),
              ),
          ],
        ),
      ),
    );
  }

  VisSceneData _sceneData(VisualizerSettings s) {
    return VisSceneData(
      bands: _displayBands,
      kickEnvelope: s.pulseEnabled ? _lastEnvelope : 0,
      kickDeform: s.pulseEnabled ? _kickDeform : 0,
      rms: VisualizerSource.instance.rms,
      brightness: s.brightness,
      depthStrength: s.depthStrength,
      explicitPlot: s.explicitPlot,
      time: _time,
      theme: s.theme,
    );
  }

  Future<void> _loadLyricsOffset(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lyricsOffsetsKey);
      if (raw == null || raw.isEmpty) return;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final v = map[path];
      if (v is num && mounted) {
        setState(() => _lyricsOffsetTenths = v.toInt());
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 左侧图标栏：主题颜色 / 地形 / 星云 / 脉冲触发 / 音频检测
// ---------------------------------------------------------------------------

class _Rail extends StatelessWidget {
  final _DrawerSection activeDrawer;
  final VisualizerForm form;
  final VisTheme theme;
  final ValueChanged<_DrawerSection> onSelectDrawer;
  final ValueChanged<VisualizerForm> onSelectForm;

  const _Rail({
    required this.activeDrawer,
    required this.form,
    required this.theme,
    required this.onSelectDrawer,
    required this.onSelectForm,
  });

  @override
  Widget build(BuildContext context) {
    final railColor = Color(theme.main).withValues(alpha: 0.8);
    Widget btn({
      required IconData icon,
      required bool active,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        child: Material(
          color: Colors.white.withValues(alpha: active ? 0.16 : 0.06),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Icon(icon, size: 21, color: railColor),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 返回播放页。
        btn(
          icon: Icons.keyboard_arrow_down_rounded,
          active: false,
          tooltip: '返回',
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(height: 10),
        btn(
          icon: Icons.palette_rounded,
          active: activeDrawer == _DrawerSection.theme,
          tooltip: '主题颜色',
          onTap: () => onSelectDrawer(_DrawerSection.theme),
        ),
        const SizedBox(height: 8),
        btn(
          icon: Icons.landscape_rounded,
          active: form == VisualizerForm.terrain,
          tooltip: '地形',
          onTap: () => onSelectForm(VisualizerForm.terrain),
        ),
        const SizedBox(height: 8),
        btn(
          icon: Icons.blur_on_rounded,
          active: form == VisualizerForm.nebula,
          tooltip: '星云',
          onTap: () => onSelectForm(VisualizerForm.nebula),
        ),
        const SizedBox(height: 8),
        btn(
          icon: Icons.bolt_rounded,
          active: activeDrawer == _DrawerSection.pulse,
          tooltip: '脉冲触发',
          onTap: () => onSelectDrawer(_DrawerSection.pulse),
        ),
        const SizedBox(height: 8),
        btn(
          icon: Icons.graphic_eq_rounded,
          active: activeDrawer == _DrawerSection.detect,
          tooltip: '音频检测',
          onTap: () => onSelectDrawer(_DrawerSection.detect),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 歌词覆盖层：逐行列表，当前行白色加圆点，其余灰暗小字；点击行跳转进度。
// ---------------------------------------------------------------------------

class _LyricsOverlay extends ConsumerStatefulWidget {
  final int offsetTenths;
  const _LyricsOverlay({required this.offsetTenths});

  @override
  ConsumerState<_LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends ConsumerState<_LyricsOverlay> {
  final ScrollController _scroll = ScrollController();
  int _lastActive = -1;

  static const double _rowExtent = 42;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<LyricLine> _lyricsFor(WidgetRef ref, QueueItem? item) {
    if (item == null) return const <LyricLine>[];
    final embedded = item.lyricsRaw?.trim() ?? '';
    if (embedded.isNotEmpty) {
      final l = ref.watch(embeddedLyricsProvider(embedded)).valueOrNull;
      if (l != null && l.isNotEmpty) return l;
    }
    return ref.watch(songLyricsProvider(item.path)).valueOrNull ??
        const <LyricLine>[];
  }

  int _activeIndex(List<LyricLine> lines, double pos) {
    final target = pos + widget.offsetTenths / 10.0;
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= target) idx = i;
    }
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
        playerProvider.select((s) => s.current));
    final position = ref.watch(
        playerProvider.select((s) => s.position));
    final lines = _lyricsFor(ref, current);
    if (lines.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '暂无歌词',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 13,
          ),
        ),
      );
    }
    final active = _activeIndex(lines, position);
    if (active != _lastActive) {
      _lastActive = active;
      if (active >= 0 && _scroll.hasClients) {
        final h = _scroll.position.viewportDimension;
        final target = (active * _rowExtent - h * 0.32).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        );
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    }

    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowExtent,
      padding: EdgeInsets.symmetric(vertical: _rowExtent * 3),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final isActive = i == active;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(
            ref.read(playerProvider.notifier).seek(lines[i].time),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  child: isActive
                      ? Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                      color: isActive
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.32),
                      fontSize: isActive ? 17 : 13,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                      height: 1.2,
                    ),
                    child: Text(
                      lines[i].text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 底部毛玻璃播放条：进度 + 上一首/播放暂停/下一首。
// ---------------------------------------------------------------------------

class _GlassPlayBar extends ConsumerStatefulWidget {
  final String songPath;
  final String title;
  const _GlassPlayBar({required this.songPath, required this.title});

  @override
  ConsumerState<_GlassPlayBar> createState() => _GlassPlayBarState();
}

class _GlassPlayBarState extends ConsumerState<_GlassPlayBar> {
  double? _dragValue;

  String _fmt(double secs) {
    if (!secs.isFinite || secs < 0) secs = 0;
    final m = secs ~/ 60;
    final s = (secs % 60).toInt();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying =
        ref.watch(playerProvider.select((s) => s.isPlaying));
    final position =
        ref.watch(playerProvider.select((s) => s.position));
    final duration =
        ref.watch(playerProvider.select((s) => s.duration));

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(_fmt(position),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2.5,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 5),
                        activeTrackColor: Colors.white.withValues(alpha: 0.85),
                        inactiveTrackColor:
                            Colors.white.withValues(alpha: 0.16),
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: _dragValue ??
                            position.clamp(0.0, duration > 0 ? duration : 1),
                        max: duration > 0 ? duration : 1,
                        onChanged: duration > 0
                            ? (v) => setState(() => _dragValue = v)
                            : null,
                        onChangeEnd: (v) {
                          _dragValue = null;
                          unawaited(
                              ref.read(playerProvider.notifier).seek(v));
                        },
                      ),
                    ),
                  ),
                  Text(_fmt(duration),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.65),
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => unawaited(
                        ref.read(playerProvider.notifier).previous()),
                    icon: const Icon(Icons.skip_previous_rounded,
                        color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Material(
                    color: Colors.white.withValues(alpha: 0.14),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => unawaited(
                          ref.read(playerProvider.notifier).toggle()),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  IconButton(
                    onPressed: () => unawaited(
                        ref.read(playerProvider.notifier).next()),
                    icon: const Icon(Icons.skip_next_rounded,
                        color: Colors.white, size: 28),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 右侧设置抽屉：脉冲触发 / 主题颜色 / 音频检测。
// ---------------------------------------------------------------------------

class _SettingsDrawer extends ConsumerWidget {
  final _DrawerSection section;
  final VoidCallback onClose;

  const _SettingsDrawer({required this.section, required this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = section != _DrawerSection.none;
    final settings = ref.watch(visualizerSettingsProvider);
    final notifier = ref.read(visualizerSettingsProvider.notifier);

    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(1.2, 0),
          child: FadeTransition(
            opacity: AlwaysStoppedAnimation(visible ? 1 : 0),
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  width: 292,
                  color: Colors.black.withValues(alpha: 0.62),
                  child: SafeArea(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                switch (section) {
                                  _DrawerSection.pulse => '脉冲触发',
                                  _DrawerSection.theme => '主题颜色',
                                  _DrawerSection.detect => '音频检测',
                                  _ => '',
                                },
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: onClose,
                              icon: Icon(Icons.close_rounded,
                                  size: 20,
                                  color: Colors.white.withValues(alpha: 0.6)),
                            ),
                          ],
                        ),
                        if (section == _DrawerSection.pulse) ...[
                          _switchTile(
                            '脉冲触发',
                            settings.pulseEnabled,
                            (v) => notifier.update((s) =>
                                s.copyWith(pulseEnabled: v)),
                          ),
                          const SizedBox(height: 10),
                          _segmentTabs(
                            labels: const ['Auto Beat', 'Advanced'],
                            activeIndex:
                                settings.pulseMode == PulseMode.autoBeat ? 0 : 1,
                            onChanged: (i) => notifier.update((s) => s.copyWith(
                                pulseMode: i == 0
                                    ? PulseMode.autoBeat
                                    : PulseMode.advanced)),
                          ),
                          const SizedBox(height: 6),
                          if (settings.pulseMode == PulseMode.autoBeat)
                            _switchTile(
                              '自动脉冲',
                              settings.autoPulse,
                              (v) => notifier
                                  .update((s) => s.copyWith(autoPulse: v)),
                            ),
                          _sliderRow(
                            '灵敏度',
                            settings.sensitivity,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(sensitivity: v)),
                            label: settings.sensitivity.toStringAsFixed(1),
                          ),
                          _sliderRow(
                            '节拍时长',
                            settings.beatDuration,
                            1,
                            30,
                            (v) => notifier
                                .update((s) => s.copyWith(beatDuration: v)),
                            label: settings.beatDuration.toStringAsFixed(1),
                          ),
                          _sliderRow(
                            '亮度',
                            settings.brightness,
                            0,
                            1,
                            (v) => notifier
                                .update((s) => s.copyWith(brightness: v)),
                            label: settings.brightness.toStringAsFixed(1),
                          ),
                          if (settings.pulseMode == PulseMode.advanced) ...[
                            const SizedBox(height: 8),
                            Text(
                              '触发频段（Advanced）',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 12,
                              ),
                            ),
                            _sliderRow(
                              '下限',
                              settings.bandStart.toDouble(),
                              0,
                              27,
                              (v) => notifier.update((s) {
                                final start = v.toInt();
                                final end = math.max(
                                    start + 1, settings.bandEnd);
                                return s.copyWith(
                                    bandStart: start, bandEnd: end);
                              }),
                              label: settings.bandStart.toString(),
                            ),
                            _sliderRow(
                              '上限',
                              settings.bandEnd.toDouble(),
                              1,
                              28,
                              (v) => notifier.update((s) {
                                final end = math.max(v.toInt(),
                                    settings.bandStart + 1);
                                return s.copyWith(bandEnd: end);
                              }),
                              label: settings.bandEnd.toString(),
                            ),
                          ],
                        ] else if (section == _DrawerSection.theme) ...[
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              for (int i = 0; i < kVisThemes.length; i++)
                                _swatch(
                                  kVisThemes[i],
                                  selected: settings.themeIndex == i,
                                  onTap: () => notifier.update(
                                      (s) => s.copyWith(themeIndex: i)),
                                ),
                            ],
                          ),
                          _sliderRow(
                            '景深强度',
                            settings.depthStrength,
                            0,
                            1,
                            (v) => notifier
                                .update((s) => s.copyWith(depthStrength: v)),
                            label: settings.depthStrength.toStringAsFixed(1),
                          ),
                          _switchTile(
                            '显式标绘图',
                            settings.explicitPlot,
                            (v) => notifier
                                .update((s) => s.copyWith(explicitPlot: v)),
                          ),
                        ] else if (section == _DrawerSection.detect) ...[
                          _sliderRow(
                            '检测源',
                            settings.detectLevel,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(detectLevel: v)),
                            label: settings.detectLevel.toStringAsFixed(1),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '调整频谱采集的输入增益，过高可能削波失真。',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _swatch(VisTheme t,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Color(t.main),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
    );
  }

  Widget _segmentTabs({
    required List<String> labels,
    required int activeIndex,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == activeIndex
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: i == activeIndex
                        ? Colors.white.withValues(alpha: 0.4)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: i == activeIndex
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.5),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sliderRow(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13.5)),
              Text(label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2.5,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              activeTrackColor: Colors.white.withValues(alpha: 0.85),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 数据源失败提示。
// ---------------------------------------------------------------------------

class _SourceFailHint extends StatelessWidget {
  final VoidCallback onRetry;
  const _SourceFailHint({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          const Text(
            '频谱采集不可用（需要麦克风权限）',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onRetry,
            child: const Text('重试',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
