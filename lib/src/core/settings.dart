import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式
enum ThemeModePreference { system, light, dark }

/// 播放过程中发生错误时的处理方式。
enum PlaybackFailureAction { playNext, pause }

/// 歌词逐字高亮样式。
///
/// `wordByWord` 是旧版逐词切换高亮，`progressive` 会在每个词内部从左到右
/// 逐渐填充高亮，`none` 则使用普通歌词文本。
enum LyricWordEffectMode { wordByWord, progressive, none }

/// 扫描支持的主流音频格式大类（与 Rust 白名单展开对应）。
const kSupportedScanFormats = <String>[
  'flac',
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'aiff',
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
    this.customBackgroundPath = '',
    this.customBackgroundBlur = 18.0,
    this.showQualityBadges = true,
    this.onlineDefaultQuality = '320k',
    this.libraryMinDurationSeconds = 0,
    this.showLyricsTranslation = true,
    this.lyricWordEffectMode = LyricWordEffectMode.progressive,
    this.desktopLyricsEnabled = false,
    this.desktopLyricsHideInApp = true,
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
  final String customBackgroundPath;
  final double customBackgroundBlur;
  final bool showQualityBadges;
  final String onlineDefaultQuality;
  final int libraryMinDurationSeconds;
  final bool showLyricsTranslation;
  final LyricWordEffectMode lyricWordEffectMode;
  final bool desktopLyricsEnabled;
  final bool desktopLyricsHideInApp;
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
    String? customBackgroundPath,
    double? customBackgroundBlur,
    bool? showQualityBadges,
    String? onlineDefaultQuality,
    int? libraryMinDurationSeconds,
    bool? showLyricsTranslation,
    LyricWordEffectMode? lyricWordEffectMode,
    bool? desktopLyricsEnabled,
    bool? desktopLyricsHideInApp,
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
      customBackgroundPath: customBackgroundPath ?? this.customBackgroundPath,
      customBackgroundBlur: customBackgroundBlur ?? this.customBackgroundBlur,
      showQualityBadges: showQualityBadges ?? this.showQualityBadges,
      onlineDefaultQuality: onlineDefaultQuality ?? this.onlineDefaultQuality,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      showLyricsTranslation:
          showLyricsTranslation ?? this.showLyricsTranslation,
      lyricWordEffectMode: lyricWordEffectMode ?? this.lyricWordEffectMode,
      desktopLyricsEnabled: desktopLyricsEnabled ?? this.desktopLyricsEnabled,
      desktopLyricsHideInApp:
          desktopLyricsHideInApp ?? this.desktopLyricsHideInApp,
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
      customBackgroundPath: prefs.getString('customBackgroundPath') ?? '',
      customBackgroundBlur: prefs.getDouble('customBackgroundBlur') ?? 18.0,
      showQualityBadges: prefs.getBool('showQualityBadges') ?? true,
      onlineDefaultQuality: prefs.getString('onlineDefaultQuality') ?? '320k',
      libraryMinDurationSeconds: prefs.getInt('libraryMinDurationSeconds') ?? 0,
      showLyricsTranslation: prefs.getBool('showLyricsTranslation') ?? true,
      lyricWordEffectMode: _lyricWordEffectModeFromPrefs(prefs),
      desktopLyricsEnabled: prefs.getBool('desktopLyricsEnabled') ?? false,
      desktopLyricsHideInApp: prefs.getBool('desktopLyricsHideInApp') ?? true,
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
      prefs.setString('customBackgroundPath', next.customBackgroundPath),
      prefs.setDouble('customBackgroundBlur', next.customBackgroundBlur),
      prefs.setBool('showQualityBadges', next.showQualityBadges),
      prefs.setString('onlineDefaultQuality', next.onlineDefaultQuality),
      prefs.setInt('libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setInt('lyricWordEffectMode', next.lyricWordEffectMode.index),
      prefs.setBool('desktopLyricsEnabled', next.desktopLyricsEnabled),
      prefs.setBool('desktopLyricsHideInApp', next.desktopLyricsHideInApp),
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
