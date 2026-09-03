import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式
enum ThemeModePreference { system, light, dark }

/// 播放详情页背景样式。
enum PlayerDetailBackgroundMode {
  coverBlur,
  wallpaperBlur,
  flowingLight,
  customImage,
}

/// 首页顶栏侧边栏按钮的位置。
enum SidebarPosition { left, right }

const kSidebarHome = 'home';
const kSidebarExplore = 'explore';
const kSidebarLocalMusic = 'localMusic';
const kSidebarFavorites = 'favorites';
const kSidebarRecent = 'recent';
const kSidebarPlugins = 'plugins';
const kSidebarAccount = 'account';
const kSidebarRecognize = 'recognize';
const kSidebarPlaylists = 'playlists';
const kSidebarSettings = 'settings';

const kDefaultSidebarItemOrder = <String>[
  kSidebarHome,
  kSidebarExplore,
  kSidebarLocalMusic,
  kSidebarFavorites,
  kSidebarRecent,
  kSidebarPlugins,
  kSidebarAccount,
  kSidebarRecognize,
  kSidebarPlaylists,
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
    this.playbackFailureAction = PlaybackFailureAction.playNext,
    this.playOtherAudioWithoutInterruption = false,
    this.lastTab = 0,
    this.keepScreenOn = true,
    this.themeMode = ThemeModePreference.system,
    this.accentColor = 0xFFEC4141,
    this.dynamicColor = false,
    this.sidebarPosition = SidebarPosition.left,
    this.sidebarItemOrder = kDefaultSidebarItemOrder,
    this.sidebarHiddenItems = const <String>[],
    this.customBackgroundPath = '',
    this.customBackgroundBlur = 18.0,
    this.playerDetailCustomImagePath = '',
    this.playerDetailBackgroundMode = PlayerDetailBackgroundMode.coverBlur,
    this.showQualityBadges = true,
    this.onlineDefaultQuality = '320k',
    this.libraryMinDurationSeconds = 0,
    this.showLyricsTranslation = true,
    this.lyricWordEffectMode = LyricWordEffectMode.progressive,
    this.lyricDisplayAlignment = LyricDisplayAlignment.left,
    this.lyricFontSize = 18.0,
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
    this.organizeRule = '{Artist}/{Album}/{Title}',
    this.scanFormats = kSupportedScanFormats,
  });

  final double volume;
  final int playMode;
  final PlaybackFailureAction playbackFailureAction;
  final bool playOtherAudioWithoutInterruption;
  final int lastTab;
  final bool keepScreenOn;
  final ThemeModePreference themeMode;
  final int accentColor;

  /// 使用 Android 12+ 系统 Material You 动态取色。
  final bool dynamicColor;
  final SidebarPosition sidebarPosition;
  final List<String> sidebarItemOrder;
  final List<String> sidebarHiddenItems;
  final String customBackgroundPath;
  final double customBackgroundBlur;
  final String playerDetailCustomImagePath;
  final PlayerDetailBackgroundMode playerDetailBackgroundMode;
  final bool showQualityBadges;
  final String onlineDefaultQuality;
  final int libraryMinDurationSeconds;
  final bool showLyricsTranslation;
  final LyricWordEffectMode lyricWordEffectMode;
  final LyricDisplayAlignment lyricDisplayAlignment;

  /// 播放详情页歌词的基础字号（未选中行）。选中行在此基础上放大。
  final double lyricFontSize;
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
  final String organizeRule;
  final List<String> scanFormats;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    PlaybackFailureAction? playbackFailureAction,
    bool? playOtherAudioWithoutInterruption,
    int? lastTab,
    bool? keepScreenOn,
    ThemeModePreference? themeMode,
    int? accentColor,
    bool? dynamicColor,
    SidebarPosition? sidebarPosition,
    List<String>? sidebarItemOrder,
    List<String>? sidebarHiddenItems,
    String? customBackgroundPath,
    double? customBackgroundBlur,
    String? playerDetailCustomImagePath,
    PlayerDetailBackgroundMode? playerDetailBackgroundMode,
    bool? showQualityBadges,
    String? onlineDefaultQuality,
    int? libraryMinDurationSeconds,
    bool? showLyricsTranslation,
    LyricWordEffectMode? lyricWordEffectMode,
    LyricDisplayAlignment? lyricDisplayAlignment,
    double? lyricFontSize,
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
    String? organizeRule,
    List<String>? scanFormats,
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
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      sidebarPosition: sidebarPosition ?? this.sidebarPosition,
      sidebarItemOrder: sidebarItemOrder ?? this.sidebarItemOrder,
      sidebarHiddenItems: sidebarHiddenItems ?? this.sidebarHiddenItems,
      customBackgroundPath: customBackgroundPath ?? this.customBackgroundPath,
      customBackgroundBlur: customBackgroundBlur ?? this.customBackgroundBlur,
      playerDetailCustomImagePath:
          playerDetailCustomImagePath ?? this.playerDetailCustomImagePath,
      playerDetailBackgroundMode:
          playerDetailBackgroundMode ?? this.playerDetailBackgroundMode,
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
      organizeRule: organizeRule ?? this.organizeRule,
      scanFormats: scanFormats ?? this.scanFormats,
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
        prefs.getInt('playbackFailureAction') ?? 0,
      ),
      playOtherAudioWithoutInterruption:
          prefs.getBool('playOtherAudioWithoutInterruption') ?? false,
      lastTab: prefs.getInt('lastTab') ?? 0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      themeMode: _themeFromInt(prefs.getInt('themeMode') ?? 0),
      accentColor: prefs.getInt('accentColor') ?? 0xFFEC4141,
      dynamicColor: prefs.getBool('dynamicColor') ?? false,
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
      customBackgroundPath: prefs.getString('customBackgroundPath') ?? '',
      customBackgroundBlur: prefs.getDouble('customBackgroundBlur') ?? 18.0,
      playerDetailCustomImagePath:
          prefs.getString('playerDetailCustomImagePath') ?? '',
      playerDetailBackgroundMode: _playerDetailBackgroundModeFromInt(
        prefs.getInt('playerDetailBackgroundMode') ?? 0,
      ),
      showQualityBadges: prefs.getBool('showQualityBadges') ?? true,
      onlineDefaultQuality: prefs.getString('onlineDefaultQuality') ?? '320k',
      libraryMinDurationSeconds: prefs.getInt('libraryMinDurationSeconds') ?? 0,
      showLyricsTranslation: prefs.getBool('showLyricsTranslation') ?? true,
      lyricWordEffectMode: _lyricWordEffectModeFromPrefs(prefs),
      lyricDisplayAlignment: _lyricDisplayAlignmentFromPrefs(prefs),
      lyricFontSize:
          (prefs.getDouble('lyricFontSize') ?? 18.0)
              .clamp(12.0, 32.0)
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
      organizeRule:
          prefs.getString('organizeRule') ?? '{Artist}/{Album}/{Title}',
      scanFormats: prefs.getStringList('scanFormats') ?? kSupportedScanFormats,
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

  PlayerDetailBackgroundMode _playerDetailBackgroundModeFromInt(int value) {
    if (value >= 0 && value < PlayerDetailBackgroundMode.values.length) {
      return PlayerDetailBackgroundMode.values[value];
    }
    return PlayerDetailBackgroundMode.coverBlur;
  }

  PlaybackFailureAction _playbackFailureActionFromInt(int v) =>
      v == PlaybackFailureAction.pause.index
      ? PlaybackFailureAction.pause
      : PlaybackFailureAction.playNext;

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
      prefs.setInt('themeMode', next.themeMode.index),
      prefs.setInt('accentColor', next.accentColor),
      prefs.setBool('dynamicColor', next.dynamicColor),
      prefs.setInt('sidebarPosition', next.sidebarPosition.index),
      prefs.setStringList(
        'sidebarItemOrder',
        normalizeSidebarItemOrder(next.sidebarItemOrder),
      ),
      prefs.setStringList('sidebarHiddenItems', next.sidebarHiddenItems),
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
      prefs.setBool('showQualityBadges', next.showQualityBadges),
      prefs.setString('onlineDefaultQuality', next.onlineDefaultQuality),
      prefs.setInt('libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setInt('lyricWordEffectMode', next.lyricWordEffectMode.index),
      prefs.setInt('lyricDisplayAlignment', next.lyricDisplayAlignment.index),
      prefs.setDouble('lyricFontSize', next.lyricFontSize),
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
      prefs.setString('organizeRule', next.organizeRule),
      prefs.setStringList('scanFormats', next.scanFormats),
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
  Future<void> setDesktopLyricsEnabled(bool value) => _save(
    (state.valueOrNull ?? const AppSettings()).copyWith(
      desktopLyricsEnabled: value,
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
