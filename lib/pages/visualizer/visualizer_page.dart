// visualizer_page.dart — 全屏音乐可视化页（5534 重写）。
//
// 1:1 对齐 sonic-topography 的核心体验：黑底 3D 场景（地形/云海、星云两
// 形态可切换）+ 左侧逐行歌词 + 中央封面幽灵层 + 底部毛玻璃播放条 + 左侧
// 竖排形态/面板图标栏 + 右侧设置抽屉（脉冲触发 / 主题颜色 / 音频检测）。
// 页面锁定横屏；单指拖拽旋转视角（OrbitControls 语义）、双指缩放、
// 点击/长按地形触发 ripple 波纹（按压时长映射强度 0.2~3.0）。
//
// 数据链：Android VisualizerBridge（输出混音 FFT+waveform，~20Hz）→
// VisualizerSource（64 段对数频段 + 帧间平滑 + FFT 失效波形兜底）→
// BeatDetector（低频窗口谱通量节拍检测，移植 beatDetector.ts）→
// CustomPainter（CPU 投影 + ui.Vertices）。
//
// 性能：场景渲染走 Ticker + repaint 通知器，歌词/进度条各自独立 watch，
// 设置变更不触发场景重建。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiOverlayStyle, DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/core/db_path.dart';
import '../../src/player/beat_detector.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/visualizer_source.dart';
import '../../src/lyrics/lyrics_models.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';
import 'visualizer_engine.dart';
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
  bool _pendingOnset = false;
  double _lastEnvelope = 0;
  List<double> _displayBands = List.filled(kVisBandCount, 0);
  // 数据源状态。
  bool _sourceReady = false;
  bool _sourceFailed = false;
  bool _noAudioHint = false; // 已启动但无音频输出提示

  // 3D 相机 + ripple 缓冲（手势直接操作）。
  final OrbitCamera _cam = OrbitCamera();
  final VisRippleBuffer _ripples = VisRippleBuffer();

  // 手势状态。
  double? _pressAt; // 按下时刻（秒）
  Offset? _pressPos;
  Offset _lastFocal = Offset.zero;
  double _lastScale = 1.0;
  bool _inScale = false;

  // 封面幽灵层（预处理后的低饱和提亮+遮罩图）。
  ui.Image? _coverImage;
  String? _coverKey;
  String? _coverSourcePath; // 原始封面文件路径（播放栏缩略图用）

  // UI 状态。
  _DrawerSection _drawer = _DrawerSection.none;
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);
  int _lyricsOffsetTenths = 0;
  String? _offsetLoadedFor;

  @override
  void initState() {
    super.initState();
    // 可视化仅限横屏：进入锁横屏，退出恢复。
    SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _ticker = createTicker(_onTick)..start();
    unawaited(_bootSource());
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _frameTick.dispose();
    unawaited(VisualizerSource.instance.stop());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
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

    // —— 节拍 ripple（对齐 MapScene onFreqTrigger：随机落点 + 强度上限 3）——
    if (_pendingOnset) {
      final rnd = math.Random();
      final ang = rnd.nextDouble() * math.pi * 2;
      final rad = math.sqrt(rnd.nextDouble()) * 20.0;
      final strength = math.min(_lastEnvelope * 2.0, 3.0);
      if (settings.form == VisualizerForm.terrain) {
        _ripples.add(math.cos(ang) * rad, math.sin(ang) * rad, strength,
            white: false, time: _time);
      } else {
        // 星云：ripple 落点用归一化偏移（-1..1）。
        _ripples.add(math.cos(ang), math.sin(ang),
            math.min(_lastEnvelope * 1.6, 2.2),
            white: false, time: _time);
      }
      _pendingOnset = false;
    }
    // 地形形变已由 ripple 直接驱动（5534），保留节拍包络供核心辉光。

    // —— 数据活跃度提示 ——
    final active = _sourceReady && VisualizerSource.instance.hasData;
    if (active && _noAudioHint) {
      _noAudioHint = false;
    } else if (!active && _sourceReady && !_noAudioHint) {
      _noAudioHint = true;
    }

    _frameTick.value++;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(visualizerSettingsProvider);
    final player = ref.watch(playerProvider);
    final current = player.current;

    // 歌曲切换时重载歌词偏移 + 封面幽灵层。
    final songPath = current?.path ?? '';
    if (songPath.isNotEmpty && _offsetLoadedFor != songPath) {
      _offsetLoadedFor = songPath;
      unawaited(_loadLyricsOffset(songPath));
    }
    final coverKey = '$songPath\u0000${current?.coverUrl ?? ''}';
    if (_coverKey != coverKey) {
      _coverKey = coverKey;
      unawaited(_loadCover(current));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 场景层（Ticker 驱动，不随 riverpod 重建）+ 轨道相机手势。
            RepaintBoundary(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onTapDown: (d) {
                  _pressAt = _time;
                  _pressPos = d.localPosition;
                },
                onTapUp: _onTapRelease,
                onTapCancel: () {
                  _pressAt = null;
                  _pressPos = null;
                },
                child: CustomPaint(
                  painter: settings.form == VisualizerForm.terrain
                      ? TerrainScenePainter(_frame(settings))
                      : NebulaScenePainter(_frame(settings)),
                  isComplex: true,
                  willChange: true,
                ),
              ),
            ),
            // 歌词覆盖层。
            Positioned(
              left: 16,
              right: 24,
              top: 0,
              bottom: 140,
              child: _LyricsOverlay(offsetTenths: _lyricsOffsetTenths),
            ),
            // 底部毛玻璃播放条（循环/上一/播放/下一/队列/设置，对齐参考图）。
            Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: _GlassPlayBar(
                songPath: songPath,
                title: current?.title ?? '未在播放',
                coverPath: _coverSourcePath,
                onOpenSettings: () => setState(() {
                  _drawer =
                      _drawer == _DrawerSection.none ? _DrawerSection.theme : _DrawerSection.none;
                }),
              ),
            ),
            // 右侧设置抽屉。
            _SettingsDrawer(
              section: _drawer,
              onClose: () => setState(() => _drawer = _DrawerSection.none),
              onFormChanged: (f) {
                // 切换形态时清空 ripple（两形态坐标系不同）。
                _ripples.clear();
                ref
                    .read(visualizerSettingsProvider.notifier)
                    .update((s) => s.copyWith(form: f));
              },
              onSectionChanged: (s) => setState(() => _drawer = s),
            ),
            // 数据源失败/无音频输出提示（居左下，短暂显示）。
            if (_sourceFailed)
              Positioned(
                left: 16,
                bottom: 150,
                child: _SourceFailHint(
                  text: '频谱采集不可用（需要麦克风权限）',
                  onRetry: _retrySource,
                ),
              )
            else if (_noAudioHint)
              Positioned(
                left: 16,
                bottom: 150,
                child: _SourceFailHint(
                  text: '未检测到音频输出，请播放音乐后重试',
                ),
              ),
          ],
        ),
      ),
    );
  }

  // —— 轨道相机手势（OrbitControls 语义）——

  void _onScaleStart(ScaleStartDetails d) {
    _inScale = true;
    _lastFocal = d.localFocalPoint;
    _lastScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final size = context.size;
    if (size == null || !_inScale) return;
    final delta = d.localFocalPoint - _lastFocal;
    _lastFocal = d.localFocalPoint;
    // 单指：纯旋转；双指：旋转+缩放（对齐 OrbitControls TOUCH.DOLLY_ROTATE）。
    _cam.orbit(delta.dx, delta.dy, size.width, size.height);
    if (d.pointerCount >= 2 && (d.scale - _lastScale).abs() > 0.0001) {
      _cam.dolly(_lastScale / d.scale);
      _lastScale = d.scale;
    }
  }

  void _onTapRelease(TapUpDetails d) {
    final pressAt = _pressAt;
    _pressAt = null;
    if (pressAt == null) return;
    final settings = ref.read(visualizerSettingsProvider);
    // 按压时长映射强度（对齐 sonic-topography：短按 0.2~0.4，长按至 3.0）。
    final hold = (_time - pressAt).clamp(0.0, 3.0);
    final strength =
        hold < 0.25 ? 0.3 : math.min(0.2 + hold * 0.93, 3.0);
    final pos = _pressPos ?? d.localPosition;
    _pressPos = null;
    if (settings.form == VisualizerForm.terrain) {
      final gp = _cam.screenToGround(pos, context.size?.width ?? 1,
          context.size?.height ?? 1);
      if (gp == null) return;
      final dist = math.sqrt(gp.dx * gp.dx + gp.dy * gp.dy);
      if (dist > 84) return; // 地形范围外
      _ripples.add(gp.dx, gp.dy, strength, white: false, time: _time);
    } else {
      // 星云：落点归一化到 -1..1。
      final size = context.size;
      if (size == null) return;
      final nx = (pos.dx / size.width - 0.5) * 2;
      final ny = (pos.dy / size.height - 0.5) * 2;
      _ripples.add(nx.clamp(-1.0, 1.0), ny.clamp(-1.0, 1.0),
          math.min(strength, 2.2), white: false, time: _time);
    }
  }

  VisFrame _frame(VisualizerSettings s) {
    return VisFrame(
      bands: _displayBands,
      kickEnvelope: s.pulseEnabled ? _lastEnvelope : 0,
      rms: VisualizerSource.instance.rms,
      time: _time,
      explicitPlot: s.explicitPlot,
      theme: s.theme,
      brightness: s.brightness,
      camera: _cam,
      ripples: _ripples,
      terrainDensity: s.terrainDensity,
      coverImage: _coverImage,
    );
  }

  /// 封面幽灵层加载：在线封面走代理落盘缓存，本地歌走 ID3 提取；
  /// 解码后预渲染「低饱和提亮 + 径向/垂直渐隐遮罩」版本（对齐
  /// CoverShaderMaterial：baseOpacity 0.5、radialMask、horizonMask）。
  Future<void> _loadCover(QueueItem? item) async {
    try {
      final songPath = item?.path ?? '';
      if (songPath.isEmpty) {
        if (mounted) {
          setState(() {
            _coverImage = null;
            _coverSourcePath = null;
          });
        }
        return;
      }
      final coverUrl = normalizeCoverImageUrl(item?.coverUrl);
      String? coverPath;
      final cacheRoot = await ref.read(appDataDirProvider.future);
      if (coverUrl.isEmpty) {
        final dbPath = await ref.read(dbPathProvider.future);
        coverPath = await getSongCover(
          dbPath: dbPath,
          cacheRoot: cacheRoot,
          path: songPath,
        );
      } else {
        final file =
            File('$cacheRoot/vis_cover_${coverUrl.hashCode}.img');
        if (!await file.exists() || await file.length() == 0) {
          final dataUrl = await proxyImage(
            url: coverUrl,
            referer: 'https://music.163.com/',
          );
          final comma = dataUrl.indexOf(',');
          if (comma > 0 && dataUrl.substring(0, comma).contains(';base64')) {
            await file.writeAsBytes(
              base64Decode(dataUrl.substring(comma + 1)),
              flush: true,
            );
          }
        }
        if (await file.exists() && await file.length() > 0) {
          coverPath = file.path;
        }
      }
      if (coverPath == null || !File(coverPath).existsSync()) {
        if (mounted) {
          setState(() {
            _coverImage = null;
            _coverSourcePath = null;
          });
        }
        return;
      }
      final bytes = await File(coverPath).readAsBytes();
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: 256);
      final src = await codec.getNextFrame();
      final masked = await _buildGhostCover(src.image);
      src.image.dispose();
      if (!mounted) return;
      setState(() {
        _coverImage = masked;
        _coverSourcePath = coverPath;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _coverImage = null;
          _coverSourcePath = null;
        });
      }
    }
  }

  /// 封面预处理：低饱和(25%)+提亮 mix(white,·,0.55) → 径向渐隐 → 垂直渐隐
  /// → 整体 alpha 0.5。烘焙成一张图，每帧零离屏直接贴。
  static Future<ui.Image> _buildGhostCover(ui.Image src) async {
    const size = 256.0;
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec, const Rect.fromLTWH(0, 0, size, size));
    final dst = const Rect.fromLTWH(0, 0, size, size);
    // ① 颜色：out = 0.55*(0.25*src + 0.75*gray(src)) + 0.45*255
    const wr = 0.299, wg = 0.587, wb = 0.114;
    c.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.matrix(<double>[
          // R
          0.55 * 0.25 + 0.55 * 0.75 * wr, 0.55 * 0.75 * wg,
          0.55 * 0.75 * wb, 0, 0.45 * 255,
          // G
          0.55 * 0.75 * wr, 0.55 * 0.25 + 0.55 * 0.75 * wg,
          0.55 * 0.75 * wb, 0, 0.45 * 255,
          // B
          0.55 * 0.75 * wr, 0.55 * 0.75 * wg,
          0.55 * 0.25 + 0.55 * 0.75 * wb, 0, 0.45 * 255,
          // A（baseOpacity 0.5）
          0, 0, 0, 0.5, 0,
        ]),
    );
    // ② 径向遮罩（radialMask：从中心立即衰减）。
    c.saveLayer(dst, Paint());
    c.drawRect(
      dst,
      Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..shader = ui.Gradient.radial(
          const Offset(size / 2, size / 2),
          size * 0.62,
          [const Color(0xFFFFFFFF), const Color(0x00FFFFFF)],
          [0.0, 1.0],
        ),
    );
    c.restore();
    // ③ 垂直遮罩（horizonMask：smoothstep(0.05,0.45,v)，顶亮底隐）。
    c.saveLayer(dst, Paint());
    c.drawRect(
      dst,
      Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          const Offset(0, size * 0.05),
          const Offset(0, size * 0.45),
          [const Color(0x00FFFFFF), const Color(0xFFFFFFFF)],
        ),
    );
    c.restore();
    final pic = rec.endRecording();
    final img = await pic.toImage(size.toInt(), size.toInt());
    pic.dispose();
    return img;
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
// 底部毛玻璃播放条：封面缩略图 + 进度 + 循环/上一首/播放暂停/下一首/
// 播放队列/设置（对齐参考图布局）。
// ---------------------------------------------------------------------------

class _GlassPlayBar extends ConsumerStatefulWidget {
  final String songPath;
  final String title;
  final String? coverPath; // 原始封面文件路径（缩略图）
  final VoidCallback onOpenSettings;
  const _GlassPlayBar({
    required this.songPath,
    required this.title,
    required this.coverPath,
    required this.onOpenSettings,
  });

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

  /// 播放队列面板：列表 + 当前行高亮，点击切歌。
  void _showQueue() {
    final player = ref.read(playerProvider);
    final queue = player.queue;
    final currentIdx = player.queueIndex;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xEE101418),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 10),
          itemCount: queue.length,
          itemBuilder: (ctx, i) {
            final song = queue[i];
            final active = i == currentIdx;
            return ListTile(
              dense: true,
              leading: Text(
                '${i + 1}',
                style: TextStyle(
                  color: active ? Colors.white : Colors.white54,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white.withValues(alpha: 0.78),
                  fontSize: 14,
                  fontWeight: active ? FontWeight.bold : FontWeight.w400,
                ),
              ),
              subtitle: song.artist.isEmpty
                  ? null
                  : Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
              trailing: active
                  ? Icon(Icons.graphic_eq_rounded,
                      size: 16, color: Colors.white.withValues(alpha: 0.8))
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(
                    ref.read(playerProvider.notifier).playIndex(i));
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying =
        ref.watch(playerProvider.select((s) => s.isPlaying));
    final position =
        ref.watch(playerProvider.select((s) => s.position));
    final duration =
        ref.watch(playerProvider.select((s) => s.duration));
    final playMode =
        ref.watch(playerProvider.select((s) => s.playMode));
    final queueLen = ref
        .watch(playerProvider.select((s) => s.queue.length));
    final notifier = ref.read(playerProvider.notifier);
    const loopIcons = [
      Icons.repeat_rounded,
      Icons.repeat_one_rounded,
      Icons.shuffle_rounded,
    ];
    final cover = widget.coverPath;

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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 封面缩略图。
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: cover != null && File(cover).existsSync()
                    ? Image.file(
                        File(cover),
                        width: 46,
                        height: 46,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : Container(
                        width: 46,
                        height: 46,
                        color: Colors.white.withValues(alpha: 0.08),
                        child: const Icon(Icons.music_note_rounded,
                            size: 20, color: Colors.white38),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
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
                        // 播放顺序（循环模式三态）。
                        IconButton(
                          tooltip: '播放顺序',
                          onPressed: () =>
                              unawaited(notifier.cyclePlayMode()),
                          icon: Icon(
                            loopIcons[playMode.clamp(0, 2)],
                            size: 22,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: () =>
                              unawaited(notifier.previous()),
                          icon: const Icon(Icons.skip_previous_rounded,
                              color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 10),
                        Material(
                          color: Colors.white.withValues(alpha: 0.14),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () =>
                                unawaited(notifier.toggle()),
                            child: SizedBox(
                              width: 50,
                              height: 50,
                              child: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          onPressed: () => unawaited(notifier.next()),
                          icon: const Icon(Icons.skip_next_rounded,
                              color: Colors.white, size: 28),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: '播放队列',
                          onPressed: queueLen > 0 ? _showQueue : null,
                          icon: Icon(
                            Icons.queue_music_rounded,
                            size: 24,
                            color: Colors.white.withValues(
                                alpha: queueLen > 0 ? 0.85 : 0.3),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: '可视化设置',
                          onPressed: widget.onOpenSettings,
                          icon: Icon(
                            Icons.tune_rounded,
                            size: 23,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
  final ValueChanged<VisualizerForm> onFormChanged;
  final ValueChanged<_DrawerSection> onSectionChanged;

  const _SettingsDrawer({
    required this.section,
    required this.onClose,
    required this.onFormChanged,
    required this.onSectionChanged,
  });

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
                                '可视化设置',
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
                        const SizedBox(height: 10),
                        // 形态切换（地形 / 星云）。
                        _segmentTabs(
                          labels: const ['地形 / 云海', '星云'],
                          activeIndex: settings.form == VisualizerForm.terrain
                              ? 0
                              : 1,
                          onChanged: (i) => onFormChanged(i == 0
                              ? VisualizerForm.terrain
                              : VisualizerForm.nebula),
                        ),
                        const SizedBox(height: 6),
                        // 分节标签。
                        _segmentTabs(
                          labels: const ['脉冲', '主题', '检测'],
                          activeIndex: switch (section) {
                            _DrawerSection.pulse => 0,
                            _DrawerSection.theme => 1,
                            _DrawerSection.detect => 2,
                            _ => 1,
                          },
                          onChanged: (i) => onSectionChanged(switch (i) {
                            0 => _DrawerSection.pulse,
                            2 => _DrawerSection.detect,
                            _ => _DrawerSection.theme,
                          }),
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
                            '地形密度',
                            settings.terrainDensity.toDouble(),
                            0,
                            100,
                            (v) => notifier.update(
                                (s) => s.copyWith(terrainDensity: v.round())),
                            label: '${settings.terrainDensity}',
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
  final String text;
  final VoidCallback? onRetry;
  const _SourceFailHint({required this.text, this.onRetry});

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
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (onRetry != null) ...[
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
        ],
      ),
    );
  }
}
