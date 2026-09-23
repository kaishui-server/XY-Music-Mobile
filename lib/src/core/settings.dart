import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式
enum ThemeModePreference { system, light, dark }

/// 播放详情页背景样式。
///
/// [coverBlur] 已从设置中移除（v2.2.0-beta2 起不再提供“封面模糊”选项），
/// 枚举值仅为兼容旧持久化索引保留，读取时会被归一化为 [flowingLight]。
enum PlayerDetailBackgroundMode {
  coverBlur,
  wallpaperBlur,
  flowingLight,
  customImage,
}

/// 播放详情页封面样式：经典方形、圆形旋转（参考 MusicFree）、沉浸式
/// （参考 MusicFree）、黑胶唱片（参考 BakaMusic）。
enum PlayerCoverStyle { classic, circle, immersive, vinyl }

/// 页面切换动画模式：平移（前后页同步推移）、层叠（前页滑入覆盖后页）、
/// 淡入淡出（两页交叉淡化）。
enum PageTransitionMode { slide, stack, fade }

/// 首页顶栏侧边栏按钮的位置。
enum SidebarPosition { left, right }

/// 首页可自定义显隐的模块 id。「猜你想听」推荐面板在探索页固定展示，
/// 不参与首页自定义；首页默认全部开启，可手动关闭。
const kHomeModuleNowPlaying = 'nowPlaying';
const kHomeModuleHotComment = 'hotComment';
const kHomeModuleStatistics = 'statistics';
const kHomeModuleLeaderboard = 'leaderboard';

const kDefaultHomeModules = <String>[
  kHomeModuleNowPlaying,
  kHomeModuleHotComment,
  kHomeModuleStatistics,
  kHomeModuleLeaderboard,
];

/// 全部合法的首页模块 id，按首页默认展示顺序排列。
const kAllHomeModules = <String>[
  kHomeModuleNowPlaying,
  kHomeModuleHotComment,
  kHomeModuleStatistics,
  kHomeModuleLeaderboard,
];

/// 归一化首页模块列表：过滤合法 id 并去重。列表表示「已启用」的模块，
/// 不在列表中的模块视为已关闭，因此不做缺省补回；默认值在读取时判断。
List<String> normalizeHomeModules(Iterable<String> stored) {
  final normalized = <String>[];
  for (final id in stored) {
    if (kAllHomeModules.contains(id) && !normalized.contains(id)) {
      normalized.add(id);
    }
  }
  return normalized;
}

const kSidebarHome = 'home';
const kSidebarExplore = 'explore';
const kSidebarLocalMusic = 'localMusic';
const kSidebarCloudMusic = 'cloudMusic';
const kSidebarFavorites = 'favorites';
const kSidebarRecent = 'recent';
const kSidebarPlugins = 'plugins';
const kSidebarAccount = 'account';
const kSidebarRecognize = 'recognize';
const kSidebarPlaylists = 'playlists';
const kSidebarDownloads = 'downloads';
const kSidebarSettings = 'settings';

const kDefaultSidebarItemOrder = <String>[
  kSidebarHome,
  kSidebarExplore,
  kSidebarLocalMusic,
  kSidebarCloudMusic,
  kSidebarFavorites,
  kSidebarRecent,
  kSidebarPlugins,
  kSidebarAccount,
  kSidebarRecognize,
  kSidebarPlaylists,
  kSidebarDownloads,
  kSidebarSettings,
];

List<String> normalizeSidebarItemOrder(Iterable<String> stored) {
  final normalized = <String>[];
  for (final id in stored) {
    if (kDefaultSidebarItemOrder.contains(id) && !normalized.contains(id)) {
      normalized.add(id);
    }
  }
  for (final id in kDefaultSidebarItemOrder) {
    if (!normalized.contains(id)) normalized.add(id);
  }
  return normalized;
}

/// 自定义底栏最多同时展示的目的地数量（Material 导航规范：2-5 个）。
const kBottomBarItemLimit = 5;

/// 归一化底栏条目：过滤合法目的地 id、去重并限制数量上限。
List<String> normalizeBottomBarItemIds(Iterable<String> stored) {
  final normalized = <String>[];
  for (final id in stored) {
    if (kDefaultSidebarItemOrder.contains(id) &&
        !normalized.contains(id) &&
        normalized.length < kBottomBarItemLimit) {
      normalized.add(id);
    }
  }
  return normalized;
}

/// 播放过程中发生错误时的处理方式。
enum PlaybackFailureAction { playNext, pause }

/// 歌词逐字高亮样式。
///
/// `wordByWord` 是旧版逐词切换高亮，`progressive` 会在每个词内部从左到右
/// 逐渐填充高亮，`none` 则使用普通歌词文本。
enum LyricWordEffectMode { wordByWord, progressive, none }

/// 播放详情页歌词的水平显示位置。
enum LyricDisplayAlignment { left, center, right }

/// 扫描支持的主流音频格式大类（与 Rust 白名单展开对应）。
/// wma/ape 与 MusicFree 的本地音乐支持格式对齐（opus 归入 ogg 大类）。
const kSupportedScanFormats = <String>[
  'flac',
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'aiff',
  'wma',
  'ape',
];

/// 移动端只使用 0=列表循环、1=单曲循环、2=随机播放。
///
/// 旧版 Rust/桌面端会话曾允许用 3 表示单曲循环；升级或导入旧数据库时
/// 必须迁移为 1，其他损坏值回退为列表循环，避免播放页按图标下标取值崩溃。
int normalizePlayMode(int value) {
  if (value == 3) return 1;
  return value >= 0 && value <= 2 ? value : 0;
}

/// 全局设置（小而美：仅移动端必需项，key 语义与桌面端一致）。
class AppSettings {
  const AppSettings({
    this.volume = 1.0,
    this.playMode = 0, // 0 顺序(列表循环) 1 单曲循环 2 随机
    this.playbackFailureAction = PlaybackFailureAction.pause,
    this.playOtherAudioWithoutInterruption = false,
    this.lastTab = 0,
    this.keepScreenOn = true,
    // 音量键调节应用内音量（不动系统媒体音量，车机上不影响导航等）。
    this.volumeKeyControlsAppVolume = true,
    this.themeMode = ThemeModePreference.system,
    this.accentColor = 0xFFEC4141,
    this.dynamicColor = false,
    this.fontFamily = '',
    this.sidebarPosition = SidebarPosition.left,
    this.sidebarItemOrder = kDefaultSidebarItemOrder,
    this.sidebarHiddenItems = const <String>[],
    this.landscapeSidebarWidth = 176.0,
    this.bottomBarEnabled = false,
    this.bottomBarItemIds = const <String>[],
    this.bottomBarShowLabels = true,
    this.customBackgroundPath = '',
    this.customBackgroundBlur = 18.0,
    this.playerDetailCustomImagePath = '',
    this.playerDetailBackgroundMode = PlayerDetailBackgroundMode.flowingLight,
    this.playerCoverStyle = PlayerCoverStyle.classic,
    this.vinylTonearm = true,
    this.pageTransitionMode = PageTransitionMode.fade,
    this.landscapeImmersiveLyrics = false,
    this.portraitImmersiveLyrics = true,
    this.homeModules = kDefaultHomeModules,
    this.showQualityBadges = true,
    this.onlineDefaultQuality = '320k',
    this.libraryMinDurationSeconds = 0,
    this.showLyricsTranslation = true,
    this.lyricWordEffectMode = LyricWordEffectMode.progressive,
    this.lyricDisplayAlignment = LyricDisplayAlignment.left,
    this.lyricFontSize = 22.0,
    this.miniLyricFontSize = 14.0,
    this.desktopLyricsEnabled = false,
    this.desktopLyricsHideInApp = true,
    this.desktopLyricsShowWordEffect = true,
    this.desktopLyricsLocked = false,
    this.desktopLyricsNoBackground = true,
    this.desktopLyricsLyricColor = 0xFFFFFFFF,
    this.desktopLyricsTranslationColor = 0xFFE1E1E6,
    this.desktopLyricsLyricFontSize = 24.0,
    this.desktopLyricsTranslationFontSize = 13.0,
    this.desktopLyricsBackgroundColor = 0xFF18181C,
    this.desktopLyricsBackgroundOpacity = .85,
    this.downloadPath = '',
    this.downloadQuality = '320k',
    this.askDownloadDetails = true,
    this.downloadLyrics = true,
    this.downloadWriteMetadata = true,
    this.organizeRule = '{Artist}/{Album}/{Title}',
    this.scanFormats = kSupportedScanFormats,
    this.equalizerEnabled = false,
    this.equalizerGains = const [],
  });

  final double volume;
  final int playMode;
  final PlaybackFailureAction playbackFailureAction;
  final bool playOtherAudioWithoutInterruption;
  final int lastTab;
  final bool keepScreenOn;

  /// 音量键调节应用内音量：应用前台时拦截音量键，只调本应用播放音量，
  /// 不动系统媒体音量（车机上不影响导航等其他声音）。
  final bool volumeKeyControlsAppVolume;
  final ThemeModePreference themeMode;
  final int accentColor;

  /// 使用 Android 12+ 系统 Material You 动态取色。
  final bool dynamicColor;

  /// 全局自定义字体的 family 名（'' = 系统默认）。字体文件由设置页
  /// 选择后复制到应用文档目录，启动时通过 FontLoader 注册。
  final String fontFamily;
  final SidebarPosition sidebarPosition;
  final List<String> sidebarItemOrder;
  final List<String> sidebarHiddenItems;

  /// 横屏常驻侧栏宽度（px）：60 为仅图标态，低于 120 自动按仅图标渲染。
  final double landscapeSidebarWidth;

  /// 自定义底栏开关：默认关闭，完成条目自定义（≥2 项）后自动开启。
  final bool bottomBarEnabled;

  /// 底栏展示的目的地 id（顺序即显示顺序，2-5 个）。
  final List<String> bottomBarItemIds;

  /// 底栏是否显示条目文字；关闭后仅显示图标（紧凑样式）。
  final bool bottomBarShowLabels;
  final String customBackgroundPath;
  final double customBackgroundBlur;
  final String playerDetailCustomImagePath;
  final PlayerDetailBackgroundMode playerDetailBackgroundMode;
  final PlayerCoverStyle playerCoverStyle;

  /// 黑胶唱片封面是否显示唱针（复刻 BakaMusic 经典款唱针）。
  final bool vinylTonearm;
  final PageTransitionMode pageTransitionMode;

  /// 横屏播放页沉浸式歌词：开启后右侧仅显示歌词，点按弹出播放栏。
  final bool landscapeImmersiveLyrics;

  /// 竖屏播放页沉浸式歌词（默认开启）：开启后封面页/歌词页铺满
  /// 内容区，点击原播放栏位置弹出播放栏，左右翻页时播放栏保持
  /// 显示，5 秒无操作自动隐藏（与横屏一致）。
  final bool portraitImmersiveLyrics;

  /// 首页已启用的模块 id（猜你想听固定展示，不在列表中即关闭）。
  final List<String> homeModules;
  final bool showQualityBadges;
  final String onlineDefaultQuality;
  final int libraryMinDurationSeconds;
  final bool showLyricsTranslation;
  final LyricWordEffectMode lyricWordEffectMode;
  final LyricDisplayAlignment lyricDisplayAlignment;

  /// 播放详情页歌词的基础字号（未选中行）。选中行在此基础上放大。
  final double lyricFontSize;

  /// 播放页封面下方迷你歌词的主行字号；超过单行阈值时自动只显示主行。
  final double miniLyricFontSize;
  final bool desktopLyricsEnabled;
  final bool desktopLyricsHideInApp;
  final bool desktopLyricsShowWordEffect;
  final bool desktopLyricsLocked;
  final bool desktopLyricsNoBackground;
  final int desktopLyricsLyricColor;
  final int desktopLyricsTranslationColor;
  final double desktopLyricsLyricFontSize;
  final double desktopLyricsTranslationFontSize;
  final int desktopLyricsBackgroundColor;
  final double desktopLyricsBackgroundOpacity;

  /// 兼容旧调用方：只要不是“不显示逐字”就视为已开启逐字效果。
  bool get enableWordEffect => lyricWordEffectMode != LyricWordEffectMode.none;
  final String downloadPath;
  final String downloadQuality;
  final bool askDownloadDetails;
  final bool downloadLyrics;

  /// 下载后向音频文件写入元数据标签（标题/艺术家/专辑/歌词/封面）。
  final bool downloadWriteMetadata;
  final String organizeRule;
  final List<String> scanFormats;

  /// 均衡器（音效）总开关：关闭时直通原始音频。
  final bool equalizerEnabled;

  /// 均衡器各频段增益（dB）。频段数量随设备而异（常见 5 段），
  /// 应用时按下标对齐，超出设备频段数的部分忽略。
  final List<double> equalizerGains;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    PlaybackFailureAction? playbackFailureAction,
    bool? playOtherAudioWithoutInterruption,
    int? lastTab,
    bool? keepScreenOn,
    bool? volumeKeyControlsAppVolume,
    ThemeModePreference? themeMode,
    int? accentColor,
    bool? dynamicColor,
    String? fontFamily,
    SidebarPosition? sidebarPosition,
    List<String>? sidebarItemOrder,
    List<String>? sidebarHiddenItems,
    double? landscapeSidebarWidth,
    bool? bottomBarEnabled,
    List<String>? bottomBarItemIds,
    bool? bottomBarShowLabels,
    String? customBackgroundPath,
    double? customBackgroundBlur,
    String? playerDetailCustomImagePath,
    PlayerDetailBackgroundMode? playerDetailBackgroundMode,
    PlayerCoverStyle? playerCoverStyle,
    bool? vinylTonearm,
    PageTransitionMode? pageTransitionMode,
    bool? landscapeImmersiveLyrics,
    bool? portraitImmersiveLyrics,
    List<String>? homeModules,
    bool? showQualityBadges,
    String? onlineDefaultQuality,
    int? libraryMinDurationSeconds,
    bool? showLyricsTranslation,
    LyricWordEffectMode? lyricWordEffectMode,
    LyricDisplayAlignment? lyricDisplayAlignment,
    double? lyricFontSize,
    double? miniLyricFontSize,
    bool? desktopLyricsEnabled,
    bool? desktopLyricsHideInApp,
    bool? desktopLyricsShowWordEffect,
    bool? desktopLyricsLocked,
    bool? desktopLyricsNoBackground,
    int? desktopLyricsLyricColor,
    int? desktopLyricsTranslationColor,
    double? desktopLyricsLyricFontSize,
    double? desktopLyricsTranslationFontSize,
    int? desktopLyricsBackgroundColor,
    double? desktopLyricsBackgroundOpacity,
    String? downloadPath,
    String? downloadQuality,
    bool? askDownloadDetails,
    bool? downloadLyrics,
    bool? downloadWriteMetadata,
    String? organizeRule,
    List<String>? scanFormats,
    bool? equalizerEnabled,
    List<double>? equalizerGains,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      playbackFailureAction:
          playbackFailureAction ?? this.playbackFailureAction,
      playOtherAudioWithoutInterruption:
          playOtherAudioWithoutInterruption ??
          this.playOtherAudioWithoutInterruption,
      lastTab: lastTab ?? this.lastTab,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      volumeKeyControlsAppVolume:
          volumeKeyControlsAppVolume ?? this.volumeKeyControlsAppVolume,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      fontFamily: fontFamily ?? this.fontFamily,
      sidebarPosition: sidebarPosition ?? this.sidebarPosition,
      sidebarItemOrder: sidebarItemOrder ?? this.sidebarItemOrder,
      sidebarHiddenItems: sidebarHiddenItems ?? this.sidebarHiddenItems,
      landscapeSidebarWidth:
          landscapeSidebarWidth ?? this.landscapeSidebarWidth,
      bottomBarEnabled: bottomBarEnabled ?? this.bottomBarEnabled,
      bottomBarItemIds: bottomBarItemIds ?? this.bottomBarItemIds,
      bottomBarShowLabels: bottomBarShowLabels ?? this.bottomBarShowLabels,
      customBackgroundPath: customBackgroundPath ?? this.customBackgroundPath,
      customBackgroundBlur: customBackgroundBlur ?? this.customBackgroundBlur,
      playerDetailCustomImagePath:
          playerDetailCustomImagePath ?? this.playerDetailCustomImagePath,
      playerDetailBackgroundMode:
          playerDetailBackgroundMode ?? this.playerDetailBackgroundMode,
      playerCoverStyle: playerCoverStyle ?? this.playerCoverStyle,
    vinylTonearm: vinylTonearm ?? this.vinylTonearm,
    pageTransitionMode: pageTransitionMode ?? this.pageTransitionMode,
      landscapeImmersiveLyrics:
          landscapeImmersiveLyrics ?? this.landscapeImmersiveLyrics,
      portraitImmersiveLyrics:
          portraitImmersiveLyrics ?? this.portraitImmersiveLyrics,
      homeModules: homeModules ?? this.homeModules,
      showQualityBadges: showQualityBadges ?? this.showQualityBadges,
      onlineDefaultQuality: onlineDefaultQuality ?? this.onlineDefaultQuality,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      showLyricsTranslation:
          showLyricsTranslation ?? this.showLyricsTranslation,
      lyricWordEffectMode: lyricWordEffectMode ?? this.lyricWordEffectMode,
      lyricDisplayAlignment:
          lyricDisplayAlignment ?? this.lyricDisplayAlignment,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      miniLyricFontSize: miniLyricFontSize ?? this.miniLyricFontSize,
      desktopLyricsEnabled: desktopLyricsEnabled ?? this.desktopLyricsEnabled,
      desktopLyricsHideInApp:
          desktopLyricsHideInApp ?? this.desktopLyricsHideInApp,
      desktopLyricsShowWordEffect:
          desktopLyricsShowWordEffect ?? this.desktopLyricsShowWordEffect,
      desktopLyricsLocked: desktopLyricsLocked ?? this.desktopLyricsLocked,
      desktopLyricsNoBackground:
          desktopLyricsNoBackground ?? this.desktopLyricsNoBackground,
      desktopLyricsLyricColor:
          desktopLyricsLyricColor ?? this.desktopLyricsLyricColor,
      desktopLyricsTranslationColor:
          desktopLyricsTranslationColor ?? this.desktopLyricsTranslationColor,
      desktopLyricsLyricFontSize:
          desktopLyricsLyricFontSize ?? this.desktopLyricsLyricFontSize,
      desktopLyricsTranslationFontSize:
          desktopLyricsTranslationFontSize ??
          this.desktopLyricsTranslationFontSize,
      desktopLyricsBackgroundColor:
          desktopLyricsBackgroundColor ?? this.desktopLyricsBackgroundColor,
      desktopLyricsBackgroundOpacity:
          desktopLyricsBackgroundOpacity ?? this.desktopLyricsBackgroundOpacity,
      downloadPath: downloadPath ?? this.downloadPath,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      askDownloadDetails: askDownloadDetails ?? this.askDownloadDetails,
      downloadLyrics: downloadLyrics ?? this.downloadLyrics,
      downloadWriteMetadata:
          downloadWriteMetadata ?? this.downloadWriteMetadata,
      organizeRule: organizeRule ?? this.organizeRule,
      scanFormats: scanFormats ?? this.scanFormats,
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerGains: equalizerGains ?? this.equalizerGains,
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await _prefs();
    return AppSettings(
      volume: prefs.getDouble('volume') ?? 1.0,
      playMode: normalizePlayMode(prefs.getInt('playMode') ?? 0),
      playbackFailureAction: _playbackFailureActionFromInt(
        prefs.getInt('playbackFailureAction') ??
            PlaybackFailureAction.pause.index,
      ),
      playOtherAudioWithoutInterruption:
          prefs.getBool('playOtherAudioWithoutInterruption') ?? false,
      lastTab: prefs.getInt('lastTab') ?? 0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      volumeKeyControlsAppVolume:
          prefs.getBool('volumeKeyControlsAppVolume') ?? true,
      themeMode: _themeFromInt(prefs.getInt('themeMode') ?? 0),
      accentColor: prefs.getInt('accentColor') ?? 0xFFEC4141,
      dynamicColor: prefs.getBool('dynamicColor') ?? false,
      fontFamily: prefs.getString('fontFamily') ?? '',
      sidebarPosition: _sidebarPositionFromInt(
        prefs.getInt('sidebarPosition') ?? 0,
      ),
      sidebarItemOrder: normalizeSidebarItemOrder(
        prefs.getStringList('sidebarItemOrder') ?? kDefaultSidebarItemOrder,
      ),
      sidebarHiddenItems:
          (prefs.getStringList('sidebarHiddenItems') ?? const [])
              .where(kDefaultSidebarItemOrder.contains)
              .toSet()
              .toList(),
      landscapeSidebarWidth: (prefs.getDouble('landscapeSidebarWidth') ?? 176)
          .clamp(60, 420),
      bottomBarEnabled: prefs.getBool('bottomBarEnabled') ?? false,
      bottomBarItemIds: normalizeBottomBarItemIds(
        prefs.getStringList('bottomBarItemIds') ?? const [],
      ),
      bottomBarShowLabels: prefs.getBool('bottomBarShowLabels') ?? true,
      customBackgroundPath: prefs.getString('customBackgroundPath') ?? '',
      customBackgroundBlur: prefs.getDouble('customBackgroundBlur') ?? 18.0,
      playerDetailCustomImagePath:
          prefs.getString('playerDetailCustomImagePath') ?? '',
      playerDetailBackgroundMode: _playerDetailBackgroundModeFromInt(
        prefs.getInt('playerDetailBackgroundMode') ?? 0,
      ),
      playerCoverStyle: _playerCoverStyleFromInt(
        prefs.getInt('playerCoverStyle') ?? 0,
      ),
      vinylTonearm: prefs.getBool('vinylTonearm') ?? true,
      pageTransitionMode: _pageTransitionModeFromInt(
        prefs.getInt('pageTransitionMode') ?? PageTransitionMode.fade.index,
      ),
      landscapeImmersiveLyrics:
          prefs.getBool('landscapeImmersiveLyrics') ?? false,
      portraitImmersiveLyrics:
          prefs.getBool('portraitImmersiveLyrics') ?? true,
      homeModules: prefs.getStringList('homeModules') == null
          ? kDefaultHomeModules
          : normalizeHomeModules(prefs.getStringList('homeModules')!),
      showQualityBadges: prefs.getBool('showQualityBadges') ?? true,
      onlineDefaultQuality: prefs.getString('onlineDefaultQuality') ?? '320k',
      libraryMinDurationSeconds: prefs.getInt('libraryMinDurationSeconds') ?? 0,
      showLyricsTranslation: prefs.getBool('showLyricsTranslation') ?? true,
      lyricWordEffectMode: _lyricWordEffectModeFromPrefs(prefs),
      lyricDisplayAlignment: _lyricDisplayAlignmentFromPrefs(prefs),
      lyricFontSize:
          (prefs.getDouble('lyricFontSize') ?? 22.0)
              .clamp(12.0, 32.0)
              .toDouble(),
      miniLyricFontSize:
          (prefs.getDouble('miniLyricFontSize') ?? 14.0)
              .clamp(10.0, 24.0)
              .toDouble(),
      desktopLyricsEnabled: prefs.getBool('desktopLyricsEnabled') ?? false,
      desktopLyricsHideInApp: prefs.getBool('desktopLyricsHideInApp') ?? true,
      desktopLyricsShowWordEffect:
          prefs.getBool('desktopLyricsShowWordEffect') ?? true,
      desktopLyricsLocked: prefs.getBool('desktopLyricsLocked') ?? false,
      desktopLyricsNoBackground:
          prefs.getBool('desktopLyricsNoBackground') ?? true,
      desktopLyricsLyricColor:
          prefs.getInt('desktopLyricsLyricColor') ?? 0xFFFFFFFF,
      desktopLyricsTranslationColor:
          prefs.getInt('desktopLyricsTranslationColor') ?? 0xFFE1E1E6,
      desktopLyricsLyricFontSize:
          (prefs.getDouble('desktopLyricsLyricFontSize') ?? 24.0)
              .clamp(16.0, 40.0)
              .toDouble(),
      desktopLyricsTranslationFontSize:
          (prefs.getDouble('desktopLyricsTranslationFontSize') ?? 13.0)
              .clamp(10.0, 28.0)
              .toDouble(),
      desktopLyricsBackgroundColor:
          prefs.getInt('desktopLyricsBackgroundColor') ?? 0xFF18181C,
      desktopLyricsBackgroundOpacity:
          prefs.getDouble('desktopLyricsBackgroundOpacity') ?? .85,
      downloadPath: prefs.getString('downloadPath') ?? '',
      downloadQuality: prefs.getString('downloadQuality') ?? '320k',
      askDownloadDetails: prefs.getBool('askDownloadDetails') ?? true,
      downloadLyrics: prefs.getBool('downloadLyrics') ?? true,
      downloadWriteMetadata: prefs.getBool('downloadWriteMetadata') ?? true,
      organizeRule:
          prefs.getString('organizeRule') ?? '{Artist}/{Album}/{Title}',
      scanFormats: prefs.getStringList('scanFormats') ?? kSupportedScanFormats,
      equalizerEnabled: prefs.getBool('equalizerEnabled') ?? false,
      equalizerGains: (prefs.getStringList('equalizerGains') ?? const [])
          .map(double.tryParse)
          .whereType<double>()
          .toList(),
    );
  }

  ThemeModePreference _themeFromInt(int v) {
    switch (v) {
      case 1:
        return ThemeModePreference.light;
      case 2:
        return ThemeModePreference.dark;
      default:
        return ThemeModePreference.system;
    }
  }

  SidebarPosition _sidebarPositionFromInt(int v) =>
      v == SidebarPosition.right.index
      ? SidebarPosition.right
      : SidebarPosition.left;

  PlayerCoverStyle _playerCoverStyleFromInt(int value) {
    if (value >= 0 && value < PlayerCoverStyle.values.length) {
      return PlayerCoverStyle.values[value];
    }
    return PlayerCoverStyle.classic;
  }

  PageTransitionMode _pageTransitionModeFromInt(int value) {
    if (value >= 0 && value < PageTransitionMode.values.length) {
      return PageTransitionMode.values[value];
    }
    return PageTransitionMode.fade;
  }

  PlayerDetailBackgroundMode _playerDetailBackgroundModeFromInt(int value) {
    // coverBlur（旧索引 0）已移除：统一迁移为流光背景。
    if (value == PlayerDetailBackgroundMode.coverBlur.index) {
      return PlayerDetailBackgroundMode.flowingLight;
    }
    if (value >= 0 && value < PlayerDetailBackgroundMode.values.length) {
      return PlayerDetailBackgroundMode.values[value];
    }
    return PlayerDetailBackgroundMode.flowingLight;
  }

  PlaybackFailureAction _playbackFailureActionFromInt(int v) =>
      v == PlaybackFailureAction.playNext.index
      ? PlaybackFailureAction.playNext
      : PlaybackFailureAction.pause;

  LyricWordEffectMode _lyricWordEffectModeFromPrefs(SharedPreferences prefs) {
    final stored = prefs.getInt('lyricWordEffectMode');
    if (stored != null &&
        stored >= 0 &&
        stored < LyricWordEffectMode.values.length) {
      return LyricWordEffectMode.values[stored];
    }
    // 旧版本只有 bool：已有用户继续保留原来的逐词样式；新用户默认渐进填充。
    final legacy = prefs.getBool('enableWordEffect');
    if (legacy != null) {
      return legacy ? LyricWordEffectMode.wordByWord : LyricWordEffectMode.none;
    }
    return LyricWordEffectMode.progressive;
  }

  LyricDisplayAlignment _lyricDisplayAlignmentFromPrefs(
    SharedPreferences prefs,
  ) {
    final stored = prefs.getInt('lyricDisplayAlignment');
    if (stored != null &&
        stored >= 0 &&
        stored < LyricDisplayAlignment.values.length) {
      return LyricDisplayAlignment.values[stored];
    }
    return LyricDisplayAlignment.left;
  }

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<void> _save(AppSettings next) async {
    state = AsyncData(next);
    final prefs = await _prefs();
    await Future.wait([
      prefs.setDouble('volume', next.volume),
      prefs.setInt('playMode', next.playMode),
      prefs.setInt('playbackFailureAction', next.playbackFailureAction.index),
      prefs.setBool(
        'playOtherAudioWithoutInterruption',
        next.playOtherAudioWithoutInterruption,
      ),
      prefs.setInt('lastTab', next.lastTab),
      prefs.setBool('keepScreenOn', next.keepScreenOn),
      prefs.setBool(
        'volumeKeyControlsAppVolume',
        next.volumeKeyControlsAppVolume,
      ),
      prefs.setInt('themeMode', next.themeMode.index),
      prefs.setInt('accentColor', next.accentColor),
      prefs.setBool('dynamicColor', next.dynamicColor),
      prefs.setString('fontFamily', next.fontFamily),
      prefs.setInt('sidebarPosition', next.sidebarPosition.index),
      prefs.setStringList(
        'sidebarItemOrder',
        normalizeSidebarItemOrder(next.sidebarItemOrder),
      ),
      prefs.setStringList('sidebarHiddenItems', next.sidebarHiddenItems),
      prefs.setDouble('landscapeSidebarWidth', next.landscapeSidebarWidth),
      prefs.setBool('bottomBarEnabled', next.bottomBarEnabled),
      prefs.setStringList('bottomBarItemIds', next.bottomBarItemIds),
      prefs.setBool('bottomBarShowLabels', next.bottomBarShowLabels),
      prefs.setString('customBackgroundPath', next.customBackgroundPath),
      prefs.setDouble('customBackgroundBlur', next.customBackgroundBlur),
      prefs.setString(
        'playerDetailCustomImagePath',
        next.playerDetailCustomImagePath,
      ),
      prefs.setInt(
        'playerDetailBackgroundMode',
        next.playerDetailBackgroundMode.index,
      ),
      prefs.setInt('playerCoverStyle', next.playerCoverStyle.index),
      prefs.setBool('vinylTonearm', next.vinylTonearm),
      prefs.setInt('pageTransitionMode', next.pageTransitionMode.index),
      prefs.setBool(
        'landscapeImmersiveLyrics',
        next.landscapeImmersiveLyrics,
      ),
      prefs.setBool(
        'portraitImmersiveLyrics',
        next.portraitImmersiveLyrics,
      ),
      prefs.setStringList('homeModules', next.homeModules),
      prefs.setBool('showQualityBadges', next.showQualityBadges),
      prefs.setString('onlineDefaultQuality', next.onlineDefaultQuality),
      prefs.setInt('libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setInt('lyricWordEffectMode', next.lyricWordEffectMode.index),
      prefs.setInt('lyricDisplayAlignment', next.lyricDisplayAlignment.index),
      prefs.setDouble('lyricFontSize', next.lyricFontSize),
      prefs.setDouble('miniLyricFontSize', next.miniLyricFontSize),
      prefs.setBool('desktopLyricsEnabled', next.desktopLyricsEnabled),
      prefs.setBool('desktopLyricsHideInApp', next.desktopLyricsHideInApp),
      prefs.setBool(
        'desktopLyricsShowWordEffect',
        next.desktopLyricsShowWordEffect,
      ),
      prefs.setBool('desktopLyricsLocked', next.desktopLyricsLocked),
      prefs.setBool(
        'desktopLyricsNoBackground',
        next.desktopLyricsNoBackground,
      ),
      prefs.setInt('desktopLyricsLyricColor', next.desktopLyricsLyricColor),
      prefs.setInt(
        'desktopLyricsTranslationColor',
        next.desktopLyricsTranslationColor,
      ),
      prefs.setDouble(
        'desktopLyricsLyricFontSize',
        next.desktopLyricsLyricFontSize,
      ),
      prefs.setDouble(
        'desktopLyricsTranslationFontSize',
        next.desktopLyricsTranslationFontSize,
      ),
      prefs.setInt(
        'desktopLyricsBackgroundColor',
        next.desktopLyricsBackgroundColor,
      ),
      prefs.setDouble(
        'desktopLyricsBackgroundOpacity',
        next.desktopLyricsBackgroundOpacity,
      ),
      prefs.setString('downloadPath', next.downloadPath),
      prefs.setString('downloadQuality', next.downloadQuality),
      prefs.setBool('askDownloadDetails', next.askDownloadDetails),
      prefs.setBool('downloadLyrics', next.downloadLyrics),
      prefs.setBool('downloadWriteMetadata', next.downloadWriteMetadata),
      prefs.setString('organizeRule', next.organizeRule),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('equalizerEnabled', next.equalizerEnabled),
      prefs.setStringList(
        'equalizerGains',
        next.equalizerGains.map((value) => value.toString()).toList(),
      ),
    ]);
  }

  Future<void> setVolume(double v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      playMode: normalizePlayMode(m),
    ),
  );
  Future<void> setPlaybackFailureAction(PlaybackFailureAction action) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      playbackFailureAction: action,
    ),
  );
  Future<void> setPlayOtherAudioWithoutInterruption(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      playOtherAudioWithoutInterruption: value,
    ),
  );
  Future<void> setLastTab(int t) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(lastTab: t));
  Future<void> setKeepScreenOn(bool v) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(keepScreenOn: v),
  );
  Future<void> setVolumeKeyControlsAppVolume(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      volumeKeyControlsAppVolume: value,
    ),
  );
  Future<void> setThemeMode(ThemeModePreference m) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(themeMode: m));
  Future<void> setAccentColor(int c) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(accentColor: c),
  );
  Future<void> setDynamicColor(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(dynamicColor: value),
  );
  Future<void> setSidebarPosition(SidebarPosition value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(sidebarPosition: value),
  );
  Future<void> setSidebarItemOrder(List<String> order) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      sidebarItemOrder: normalizeSidebarItemOrder(order),
    ),
  );
  Future<void> setSidebarItemVisible(String id, bool visible) {
    final current = state.valueOrNull ?? const AppSettings();
    final hidden = current.sidebarHiddenItems.toSet();
    if (visible) {
      hidden.remove(id);
    } else if (kDefaultSidebarItemOrder.contains(id)) {
      hidden.add(id);
    }
    return _save(current.copyWith(sidebarHiddenItems: hidden.toList()));
  }

  /// 横屏侧栏宽度：拖动分割线实时调用，持久化由防抖后的拖动结束统一完成。
  Future<void> setLandscapeSidebarWidth(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      landscapeSidebarWidth: value.clamp(60, 420),
    ),
  );

  /// 手动开关底栏；条目不足 2 个时无法开启（保持关闭）。
  Future<void> setBottomBarEnabled(bool value) {
    final current = state.valueOrNull ?? const AppSettings();
    if (value && current.bottomBarItemIds.length < 2) {
      return Future.value();
    }
    return _save(current.copyWith(bottomBarEnabled: value));
  }

  /// 更新底栏条目（顺序即显示顺序）。
  ///
  /// 「完成自定义设置后打开」：条目从不足 2 个增加到 ≥2 个时自动开启；
  /// 降回不足 2 个时自动关闭；手动关闭后仅调整顺序/增删（保持 ≥2 个）
  /// 不改变开关状态。
  Future<void> setBottomBarItems(List<String> ids) {
    final current = state.valueOrNull ?? const AppSettings();
    final normalized = normalizeBottomBarItemIds(ids);
    final wasBelowMin = current.bottomBarItemIds.length < 2;
    final nowAtLeastMin = normalized.length >= 2;
    return _save(
      current.copyWith(
        bottomBarItemIds: normalized,
        bottomBarEnabled: nowAtLeastMin && (wasBelowMin || current.bottomBarEnabled),
      ),
    );
  }

  /// 底栏条目文字显示开关：关闭后底栏仅显示图标。
  Future<void> setBottomBarShowLabels(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      bottomBarShowLabels: value,
    ),
  );

  Future<void> setCustomBackgroundPath(String path) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      customBackgroundPath: path,
    ),
  );
  Future<void> setCustomBackgroundBlur(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      customBackgroundBlur: value.clamp(0, 40).toDouble(),
    ),
  );
  Future<void> setPlayerDetailCustomImagePath(String path) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      playerDetailCustomImagePath: path,
    ),
  );
  Future<void> setPlayerDetailBackgroundMode(PlayerDetailBackgroundMode mode) =>
      _save(
        (state.valueOrNull ?? const AppSettings()).copyWith(
          playerDetailBackgroundMode: mode,
        ),
      );
  Future<void> setPlayerCoverStyle(PlayerCoverStyle style) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      playerCoverStyle: style,
    ),
  );
  Future<void> setVinylTonearm(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      vinylTonearm: value,
    ),
  );
  Future<void> setPageTransitionMode(PageTransitionMode mode) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      pageTransitionMode: mode,
    ),
  );
  Future<void> setLandscapeImmersiveLyrics(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      landscapeImmersiveLyrics: value,
    ),
  );
  Future<void> setPortraitImmersiveLyrics(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      portraitImmersiveLyrics: value,
    ),
  );

  /// 首页模块显隐：开启时按默认顺序追加，关闭时移除。
  Future<void> setHomeModuleEnabled(String id, bool enabled) {
    final current = state.valueOrNull ?? const AppSettings();
    final modules = current.homeModules.toSet();
    if (enabled) {
      modules.add(id);
    } else {
      modules.remove(id);
    }
    final ordered = kAllHomeModules
        .where(modules.contains)
        .toList(growable: false);
    return _save(current.copyWith(homeModules: ordered));
  }
  Future<void> setShowQualityBadges(bool v) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(showQualityBadges: v),
  );
  Future<void> setOnlineDefaultQuality(String q) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      onlineDefaultQuality: q,
    ),
  );
  Future<void> setLibraryMinDurationSeconds(int s) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      libraryMinDurationSeconds: s,
    ),
  );
  Future<void> setShowLyricsTranslation(bool v) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      showLyricsTranslation: v,
    ),
  );
  Future<void> setLyricWordEffectMode(LyricWordEffectMode mode) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      lyricWordEffectMode: mode,
    ),
  );
  Future<void> setLyricDisplayAlignment(LyricDisplayAlignment alignment) =>
      _save(
        (state.valueOrNull ?? const AppSettings()).copyWith(
          lyricDisplayAlignment: alignment,
        ),
      );

  /// 歌词字号写入时做范围约束，防止异常值把歌词渲染成不可用状态。
  Future<void> setLyricFontSize(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      lyricFontSize: value.clamp(12.0, 32.0).toDouble(),
    ),
  );

  /// 迷你歌词字号约束在 10~24；封面下方展示区域固定 56dp 高，
  /// 超过 20 时副行（翻译/下一句）自动隐藏，只保留主行。
  Future<void> setMiniLyricFontSize(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      miniLyricFontSize: value.clamp(10.0, 24.0).toDouble(),
    ),
  );

  /// 全局自定义字体 family；传空字符串恢复系统默认。
  Future<void> setFontFamily(String value) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(fontFamily: value));
  Future<void> setDesktopLyricsEnabled(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsEnabled: value,
    ),
  );

  /// 均衡器开关与频段增益。增益值按设备频段数截断，写入后由播放器
  /// 侧的应用方法实时生效。
  Future<void> setEqualizerEnabled(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      equalizerEnabled: value,
    ),
  );
  Future<void> setEqualizerGains(List<double> gains) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      equalizerGains: List<double>.unmodifiable(
        gains.map((value) => value.clamp(-15.0, 15.0).toDouble()),
      ),
    ),
  );
  Future<void> setDesktopLyricsHideInApp(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsHideInApp: value,
    ),
  );
  Future<void> setDesktopLyricsShowWordEffect(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsShowWordEffect: value,
    ),
  );
  Future<void> setDesktopLyricsLocked(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsLocked: value,
    ),
  );
  Future<void> setDesktopLyricsNoBackground(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsNoBackground: value,
    ),
  );
  Future<void> setDesktopLyricsLyricColor(int value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsLyricColor: value,
    ),
  );
  Future<void> setDesktopLyricsTranslationColor(int value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsTranslationColor: value,
    ),
  );
  Future<void> setDesktopLyricsLyricFontSize(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsLyricFontSize: value.clamp(16.0, 40.0).toDouble(),
    ),
  );
  Future<void> setDesktopLyricsTranslationFontSize(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsTranslationFontSize: value.clamp(10.0, 28.0).toDouble(),
    ),
  );
  Future<void> setDesktopLyricsBackgroundColor(int value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsBackgroundColor: value,
    ),
  );
  Future<void> setDesktopLyricsBackgroundOpacity(double value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsBackgroundOpacity: value.clamp(0.1, 1.0).toDouble(),
    ),
  );

  /// 兼容旧调用方，新的设置页面使用三档模式接口。
  Future<void> setEnableWordEffect(bool v) => setLyricWordEffectMode(
    v ? LyricWordEffectMode.wordByWord : LyricWordEffectMode.none,
  );
  Future<void> setDownloadPath(String p) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(downloadPath: p),
  );
  Future<void> setDownloadQuality(String q) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(downloadQuality: q),
  );
  Future<void> setAskDownloadDetails(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      askDownloadDetails: value,
    ),
  );
  Future<void> setDownloadLyrics(bool v) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(downloadLyrics: v),
  );
  Future<void> setDownloadWriteMetadata(bool v) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      downloadWriteMetadata: v,
    ),
  );
  Future<void> setOrganizeRule(String r) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(organizeRule: r),
  );
  Future<void> setScanFormats(List<String> f) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: f),
  );
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
