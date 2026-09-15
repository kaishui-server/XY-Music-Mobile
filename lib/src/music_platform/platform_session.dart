import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 第三方在线音乐平台。
enum MusicPlatform { netease, qq, kugou }

extension MusicPlatformX on MusicPlatform {
  String get label => switch (this) {
    MusicPlatform.netease => '网易云音乐',
    MusicPlatform.qq => 'QQ音乐',
    MusicPlatform.kugou => '酷狗音乐',
  };

  /// 洛雪音源 id（与 importLxPlaylist 的 source 一致，歌单导入复用
  /// lx_playlist_import 的直连详情接口）。
  String get lxSource => switch (this) {
    MusicPlatform.netease => 'wy',
    MusicPlatform.qq => 'tx',
    MusicPlatform.kugou => 'kg',
  };

  /// 从路由参数解析平台。
  static MusicPlatform? fromName(String? name) => switch (name) {
    'netease' || 'wy' => MusicPlatform.netease,
    'qq' || 'tx' => MusicPlatform.qq,
    'kugou' || 'kg' => MusicPlatform.kugou,
    _ => null,
  };
}

/// 第三方平台的登录会话。
///
/// 凭证（cookie/token 等）以 JSON Map 持久化在设备本地，仅用于拉取
/// 该账号的歌单列表，不做任何云端转发。
class MusicPlatformAccount {
  const MusicPlatformAccount({
    required this.platform,
    required this.userId,
    required this.nickname,
    this.avatarUrl = '',
    this.credentials = const {},
    this.loggedInAt,
  });

  final MusicPlatform platform;

  /// 平台用户唯一标识（网易 uid / QQ uin / 酷狗 userid）。
  final String userId;

  final String nickname;

  final String avatarUrl;

  /// 平台凭证：网易 `MUSIC_U`；QQ `qm_keyst`；酷狗 `token`。
  final Map<String, String> credentials;

  final DateTime? loggedInAt;

  MusicPlatformAccount copyWith({
    String? userId,
    String? nickname,
    String? avatarUrl,
    Map<String, String>? credentials,
  }) => MusicPlatformAccount(
    platform: platform,
    userId: userId ?? this.userId,
    nickname: nickname ?? this.nickname,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    credentials: credentials ?? this.credentials,
    loggedInAt: loggedInAt,
  );

  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'userId': userId,
    'nickname': nickname,
    'avatarUrl': avatarUrl,
    'credentials': credentials,
    'loggedInAt': loggedInAt?.millisecondsSinceEpoch,
  };

  static MusicPlatformAccount? fromJson(Map<String, dynamic> json) {
    final platform = MusicPlatformX.fromName(json['platform']?.toString());
    final userId = json['userId']?.toString() ?? '';
    if (platform == null || userId.isEmpty) return null;
    final rawCredentials = json['credentials'];
    final loggedInAt = json['loggedInAt'];
    return MusicPlatformAccount(
      platform: platform,
      userId: userId,
      nickname: json['nickname']?.toString() ?? userId,
      avatarUrl: json['avatarUrl']?.toString() ?? '',
      credentials: {
        for (final entry in (rawCredentials is Map ? rawCredentials.entries : const Iterable.empty()))
          entry.key.toString(): entry.value.toString(),
      },
      loggedInAt: loggedInAt is num
          ? DateTime.fromMillisecondsSinceEpoch(loggedInAt.toInt())
          : null,
    );
  }
}

const _prefsKey = 'music_platform_sessions';

/// 各平台的登录会话集合，shared_preferences 持久化。
class MusicPlatformSessions {
  const MusicPlatformSessions({this.accounts = const {}});

  final Map<MusicPlatform, MusicPlatformAccount> accounts;

  MusicPlatformAccount? accountOf(MusicPlatform platform) => accounts[platform];

  MusicPlatformSessions withAccount(MusicPlatformAccount account) =>
      MusicPlatformSessions(accounts: {...accounts, account.platform: account});

  MusicPlatformSessions without(MusicPlatform platform) {
    if (!accounts.containsKey(platform)) return this;
    final next = Map<MusicPlatform, MusicPlatformAccount>.of(accounts)
      ..remove(platform);
    return MusicPlatformSessions(accounts: next);
  }
}

class MusicPlatformSessionsNotifier
    extends AsyncNotifier<MusicPlatformSessions> {
  @override
  Future<MusicPlatformSessions> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const MusicPlatformSessions();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const MusicPlatformSessions();
      final accounts = <MusicPlatform, MusicPlatformAccount>{};
      for (final value in decoded.whereType<Map>()) {
        final account = MusicPlatformAccount.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (account != null) accounts[account.platform] = account;
      }
      return MusicPlatformSessions(accounts: accounts);
    } catch (_) {
      return const MusicPlatformSessions();
    }
  }

  Future<void> _persist(MusicPlatformSessions sessions) async {
    state = AsyncValue.data(sessions);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([
        for (final account in sessions.accounts.values) account.toJson(),
      ]),
    );
  }

  /// 登录成功后保存/覆盖某平台的会话。
  Future<void> saveAccount(MusicPlatformAccount account) async {
    final current = state.valueOrNull ?? const MusicPlatformSessions();
    await _persist(current.withAccount(account));
  }

  Future<void> logout(MusicPlatform platform) async {
    final current = state.valueOrNull ?? const MusicPlatformSessions();
    await _persist(current.without(platform));
  }
}

final musicPlatformSessionsProvider = AsyncNotifierProvider<
  MusicPlatformSessionsNotifier,
  MusicPlatformSessions
>(MusicPlatformSessionsNotifier.new);
