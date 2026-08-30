import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

/// 默认后端地址与签名密钥（与桌面端一致）。
const defaultAuthBaseUrl = 'https://cosn.xymusic.cc:8081/api';
const defaultAuthApiSecret =
    '53dab6e42c380c4502f73b40fc2e9af9c2ee523ecb92b6884ad17156c9c762af';

/// 认证用户（XY Music 账号登录）。
class AuthUser {
  final String id;
  final String username;
  final String nickname;
  final String email;
  final String? avatar;
  final String? xymusicId;
  final String role;
  const AuthUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.email,
    this.avatar,
    this.xymusicId,
    this.role = '',
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) {
    final idRaw = j['user_id'] ?? j['id'] ?? '';
    final username = (j['username'] as String?) ?? '';
    final nickname = ((j['nickname'] as String?)?.isNotEmpty ?? false)
        ? (j['nickname'] as String)
        : username;
    // 读取一次旧版本地凭据字段，保存或刷新资料后会统一写回 xymusic_id。
    final xymusic = j['xymusic_id'] ?? j['ciyuanxi_id'];
    return AuthUser(
      id: idRaw.toString(),
      username: username,
      nickname: nickname,
      email: (j['email'] as String?) ?? '',
      avatar: (j['avatar_url'] ?? j['avatar']) as String?,
      xymusicId: xymusic?.toString(),
      role: (j['role'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'nickname': nickname,
    'email': email,
    'avatar': avatar,
    'xymusic_id': xymusicId,
    'role': role,
  };
}

class AuthState {
  final AuthUser? user;
  final bool loading;
  final String? error;
  const AuthState({this.user, this.loading = false, this.error});
  bool get isLoggedIn => user != null;

  AuthState copyWith({
    AuthUser? user,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// 用户提交的反馈记录，与服务端 list_my_feedback 返回结构保持一致。
class UserFeedbackItem {
  const UserFeedbackItem({
    required this.id,
    required this.title,
    required this.content,
    required this.feedbackType,
    required this.images,
    required this.status,
    required this.category,
    required this.assignee,
    required this.adminReply,
    required this.repliedBy,
    required this.resolveNote,
    required this.rejectReason,
    required this.resolveImages,
    required this.hasErrorLogs,
    required this.hasAllLogs,
    required this.createdAt,
    required this.repliedAt,
    required this.updatedAt,
  });

  final int id;
  final String title;
  final String content;
  final String feedbackType;
  final List<String> images;
  final String status;
  final String category;
  final String assignee;
  final String adminReply;
  final String repliedBy;
  final String resolveNote;
  final String rejectReason;
  final List<String> resolveImages;
  final bool hasErrorLogs;
  final bool hasAllLogs;
  final String createdAt;
  final String repliedAt;
  final String updatedAt;

  factory UserFeedbackItem.fromJson(Map<String, dynamic> json) {
    List<String> strings(dynamic value) => value is List
        ? value
              .map((item) => item?.toString().trim() ?? '')
              .where((item) => item.isNotEmpty)
              .toList()
        : const <String>[];
    return UserFeedbackItem(
      id: (json['id'] as num?)?.toInt() ?? int.tryParse('${json['id']}') ?? 0,
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      feedbackType: json['feedbackType']?.toString() ?? 'problem',
      images: strings(json['images']),
      status: json['status']?.toString() ?? 'pending',
      category: json['category']?.toString() ?? 'feedback',
      assignee: json['assignee']?.toString() ?? '',
      adminReply:
          json['adminReply']?.toString() ??
          json['admin_reply']?.toString() ??
          '',
      repliedBy:
          json['repliedBy']?.toString() ?? json['replied_by']?.toString() ?? '',
      resolveNote: json['resolveNote']?.toString() ?? '',
      rejectReason:
          json['rejectReason']?.toString() ??
          json['reject_reason']?.toString() ??
          '',
      resolveImages: strings(json['resolveImages']),
      hasErrorLogs: json['hasErrorLogs'] == true,
      hasAllLogs: json['hasAllLogs'] == true,
      createdAt: json['createdAt']?.toString() ?? '',
      repliedAt: json['repliedAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
    );
  }
}

/// 人机验证题目（内置算术题模式，与桌面端 get_captcha 一致）。
class HumanCaptcha {
  final String captchaId;
  final String question;
  final int? expireSeconds;
  const HumanCaptcha({
    required this.captchaId,
    required this.question,
    this.expireSeconds,
  });

  factory HumanCaptcha.fromJson(Map<String, dynamic> j) {
    // 兼容不同版本服务端的字段命名，避免收到题目后因字段名不一致而
    // 显示空白题目。
    final id = j['captcha_id'] ?? j['captchaId'] ?? j['id'];
    final question = j['question'] ?? j['captcha_question'] ?? j['captchaQuestion'];
    final expire = j['expire_seconds'] ?? j['expireSeconds'];
    return HumanCaptcha(
      captchaId: id?.toString().trim() ?? '',
      question: question?.toString().trim() ?? '',
      expireSeconds: expire is num ? expire.toInt() : int.tryParse('$expire'),
    );
  }
}

/// 人机验证结果载荷（算术题：id + 答案）。
class HumanCaptchaPayload {
  final String captchaId;
  final String captchaAnswer;
  const HumanCaptchaPayload({
    required this.captchaId,
    required this.captchaAnswer,
  });

  /// 并入请求体的 captcha 字段（与桌面端 withCaptcha 一致）。
  Map<String, dynamic> toBodyFields() => {
    'captcha_id': captchaId,
    'captcha_answer': captchaAnswer,
  };
}

class BackendAnnouncement {
  const BackendAnnouncement({
    required this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
    this.type = 'info',
    this.actionUrl = '',
    this.actionText = '',
  });

  final String id;
  final String title;
  final String content;
  final String updatedAt;
  final String type;
  final String actionUrl;
  final String actionText;
}

class BackendRelease {
  const BackendRelease({
    this.id = 0,
    required this.version,
    required this.downloadUrl,
    required this.content,
    required this.status,
  });

  final int id;
  final String version;
  final String downloadUrl;
  final String content;
  final String status;
}

/// 将服务端返回的相对安装包路径转换为可下载的完整地址。
String resolveBackendDownloadUrl(String value) {
  final raw = value.trim();
  if (raw.isEmpty || raw.startsWith('http://') || raw.startsWith('https://')) {
    return raw;
  }
  final base = defaultAuthBaseUrl.replaceFirst(RegExp(r'/api/?$'), '');
  return '$base/${raw.replaceFirst(RegExp(r'^/+'), '')}';
}

class _ClientMetadata {
  const _ClientMetadata({
    required this.appVersion,
    required this.osVersion,
    required this.deviceModel,
  });

  final String appVersion;
  final String osVersion;
  final String deviceModel;

  Map<String, dynamic> toRequestFields() => {
    'client_type': 'mobile',
    'app_version': appVersion,
    'os_version': osVersion,
    'device_model': deviceModel,
    'platform': defaultTargetPlatform.name,
  };
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState()) {
    init();
  }

  final Ref _ref;
  final Random _rand = Random();
  Future<_ClientMetadata>? _clientMetadataFuture;
  final Completer<void> _initCompleter = Completer<void>();

  /// 登录态从磁盘恢复完成后完成。云同步等启动期服务必须等待它，
  /// 否则可能读到空的 currentUser 而错误地跳过初始化。
  Future<void> get ready => _initCompleter.future;

  /// 当前已登录用户的只读快照，供同步等服务层读取，避免直接暴露
  /// StateNotifier 的受保护 state 成员。
  AuthUser? get currentUser => state.user;

  Future<_ClientMetadata> _clientMetadata() =>
      _clientMetadataFuture ??= _loadClientMetadata();

  Future<_ClientMetadata> _loadClientMetadata() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('com.xymusic.mobile/device_info');
        final info = await channel.invokeMapMethod<String, dynamic>(
          'getDeviceInfo',
        );
        final manufacturer = info?['manufacturer']?.toString().trim() ?? '';
        final model = info?['model']?.toString().trim() ?? '';
        final lowerManufacturer = manufacturer.toLowerCase();
        final deviceModel =
            model.toLowerCase().startsWith(lowerManufacturer) ||
                manufacturer.isEmpty
            ? model
            : '$manufacturer $model'.trim();
        return _ClientMetadata(
          appVersion: info?['appVersion']?.toString().trim() ?? '1.3.1',
          osVersion: 'Android ${info?['osVersion'] ?? ''}'.trim(),
          deviceModel: deviceModel.isEmpty ? 'Android 手机' : deviceModel,
        );
      } catch (_) {
        // 单元测试或旧宿主没有原生通道时使用可识别的回退值。
      }
    }
    return _ClientMetadata(
      appVersion: '1.3.1',
      osVersion: defaultTargetPlatform.name,
      deviceModel: '${defaultTargetPlatform.name} 设备',
    );
  }

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 设备 ID（持久化，用于登录签名）。
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('deviceId');
    if (id == null || id.isEmpty) {
      id = _randHex(16);
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  String _randHex(int len) {
    const hex = '0123456789abcdef';
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(hex[_rand.nextInt(16)]);
    }
    return sb.toString();
  }

  /// 启动时确保默认基地址/密钥并加载已有凭证。
  Future<void> init() async {
    try {
      final dir = await _dataDir();
      final previousBaseUrl = await authGetBaseUrl(dataDir: dir);
      final previousApiSecret = await authGetApiSecret(dataDir: dir);
      final backendChanged =
          previousBaseUrl.trim() != defaultAuthBaseUrl ||
          previousApiSecret.trim() != defaultAuthApiSecret;
      if (backendChanged) {
        // 旧服务与新服务的用户库、token 空间彼此独立。迁移后继续沿用旧用户
        // 会造成界面显示“已登录”，但排行榜和资料实际属于另一台服务器。
        await authClearCredentials(dataDir: dir);
      }
      await authSetBaseUrl(dataDir: dir, baseUrl: defaultAuthBaseUrl);
      await authSetApiSecret(dataDir: dir, apiSecret: defaultAuthApiSecret);
      final credsJson = await authGetCredentials(dataDir: dir);
      if (credsJson.trim().isNotEmpty && credsJson != 'null') {
        final j = jsonDecode(credsJson) as Map<String, dynamic>;
        final userJson = j['user'];
        if (userJson is Map<String, dynamic>) {
          state = AuthState(user: AuthUser.fromJson(userJson));
        }
      }
    } catch (_) {
      // 无凭证或初始化失败，保持未登录。
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  /// 发送带签名的账号请求，校验 code===200 并返回 data。
  Future<Map<String, dynamic>> _requestAction(
    String action,
    Map<String, dynamic> body, {
    int? fetchTimeoutMs,
  }) async {
    final dir = await _dataDir();
    final res = await authAuthedRequest(
      dataDir: dir,
      action: action,
      bodyJson: jsonEncode(body),
      fetchTimeoutMs: fetchTimeoutMs == null
          ? null
          : BigInt.from(fetchTimeoutMs),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    if (code != 200) {
      throw AuthException(
        (j['msg'] as String?)?.isNotEmpty == true
            ? _userFacingMessage(j['msg'] as String)
            : '请求失败（code $code）',
      );
    }
    final data = j['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is List) return {'items': data};
    return const {};
  }

  /// 供排行榜、同步等非账号页面复用同一套后端签名请求。
  Future<Map<String, dynamic>> requestBackendAction(
    String action,
    Map<String, dynamic> body, {
    int? fetchTimeoutMs,
  }) => _requestAction(action, body, fetchTimeoutMs: fetchTimeoutMs);

  /// 上报移动端启动事件，供服务端后台统计活跃设备。
  Future<void> reportAppOpen() async {
    final metadata = await _clientMetadata();
    await _requestAction('open', {
      'device_id': await _deviceId(),
      'xymusic_id': state.user?.xymusicId ?? '',
      ...metadata.toRequestFields(),
    }, fetchTimeoutMs: 8000);
  }

  /// 上报每个插件的网络搜索结果，不影响实际搜索流程。
  Future<void> reportSearch({
    required String keyword,
    required String source,
    required int resultCount,
  }) async {
    await _requestAction('search', {
      'device_id': await _deviceId(),
      'keyword': keyword.trim(),
      'source': source,
      'result_count': resultCount,
    }, fetchTimeoutMs: 8000);
  }

  Future<BackendAnnouncement?> fetchAnnouncement() async {
    final data = await _requestAction('get_announcement', {
      'xymusic_id': state.user?.xymusicId ?? '',
      'device_id': await _deviceId(),
    }, fetchTimeoutMs: 15000);
    final id = data['id']?.toString() ?? '';
    final title = data['title']?.toString() ?? '';
    final content = data['content']?.toString() ?? '';
    if (id.isEmpty || title.isEmpty || content.isEmpty) return null;
    return BackendAnnouncement(
      id: id,
      title: title,
      content: content,
      updatedAt: data['updatedAt']?.toString() ?? '',
      type: data['type']?.toString() ?? 'info',
      actionUrl: data['actionUrl']?.toString() ?? '',
      actionText: data['actionText']?.toString() ?? '',
    );
  }

  Future<void> confirmAnnouncement(BackendAnnouncement announcement) async {
    await _requestAction('confirm_announcement', {
      'announcement_id': announcement.id,
      'announcement_updated_at': announcement.updatedAt,
      'xymusic_id': state.user?.xymusicId ?? '',
      'device_id': await _deviceId(),
    }, fetchTimeoutMs: 15000);
  }

  Future<BackendRelease?> fetchLatestRelease() async {
    final data = await _requestAction(
      'get_latest_version',
      const {},
      fetchTimeoutMs: 15000,
    );
    final version = data['version']?.toString() ?? '';
    if (version.isEmpty) return null;
    return BackendRelease(
      id: (data['id'] as num?)?.toInt() ?? int.tryParse('${data['id']}') ?? 0,
      version: version,
      downloadUrl: data['download_url']?.toString() ?? '',
      content: data['content']?.toString() ?? '',
      status: data['status']?.toString() ?? '',
    );
  }

  /// 获取当前客户端版本号，供移动端更新提示比较使用。
  Future<String> currentAppVersion() async =>
      (await _clientMetadata()).appVersion;

  Future<void> _saveAuth(String token, Map<String, dynamic> data) async {
    final dir = await _dataDir();
    final user = AuthUser.fromJson(data);
    await authSaveCredentials(
      dataDir: dir,
      token: token,
      userJson: jsonEncode(user.toJson()),
    );
    state = AuthState(user: user);
  }

  /// 获取一次性人机验证题（算术题，purpose=auth）。
  Future<HumanCaptcha> fetchCaptcha() async {
    // 验证弹窗不能无限停留在“加载中”。网络或服务端数据库异常时，
    // 给请求设置一个有限超时，让界面进入可重试状态。
    final data = await _requestAction(
      'get_captcha',
      {'purpose': 'auth'},
      fetchTimeoutMs: 12000,
    ).timeout(const Duration(seconds: 15));
    final captcha = HumanCaptcha.fromJson(data);
    if (captcha.captchaId.isEmpty || captcha.question.isEmpty) {
      throw AuthException('验证题返回内容无效，请点击换一题重试');
    }
    return captcha;
  }

  /// 预校验人机验证答案。答案正确返回，错误抛 AuthException。
  /// 此接口只确认答案，不消费验证码；后续登录/注册/发码请求会再次校验并消费。
  Future<void> verifyCaptcha(HumanCaptchaPayload payload) async {
    await _requestAction(
      'verify_captcha',
      {
        'purpose': 'auth',
        'captcha_id': payload.captchaId,
        'captcha_answer': payload.captchaAnswer,
      },
      fetchTimeoutMs: 12000,
    ).timeout(const Duration(seconds: 15));
  }

  /// 发送邮箱验证码（注册/找回密码等场景），需先通过人机验证。
  Future<String> sendCode(
    String email,
    String type, {
    HumanCaptchaPayload? captcha,
    String? xymusicId,
  }) async {
    final data = await _requestAction('send_verify_code', {
      'email': email,
      'type': type,
      if (xymusicId != null && xymusicId.trim().isNotEmpty)
        'xymusic_id': xymusicId.trim(),
      if (captcha != null) ...captcha.toBodyFields(),
    });
    return _userFacingMessage(
      (data['message'] as String?) ?? (data['msg'] as String?) ?? '验证码已发送到邮箱',
    );
  }

  /// XY Music 账号登录。
  Future<void> login({
    required String xymusicId,
    required String password,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final metadata = await _clientMetadata();
      final data = await _requestAction('user_login', {
        'xymusic_id': xymusicId.trim(),
        'password': password,
        'device_id': await _deviceId(),
        ...metadata.toRequestFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException('登录响应无效');
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, '登录失败'));
    }
  }

  /// 用户注册（注册成功后自动登录）。
  Future<String?> register({
    required String xymusicId,
    required String nickname,
    required String password,
    required String email,
    required String code,
    HumanCaptchaPayload? captcha,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final metadata = await _clientMetadata();
      final data = await _requestAction('register', {
        'xymusic_id': xymusicId.trim(),
        'nickname': nickname.trim(),
        'password': password,
        'email': email.trim(),
        'verify_code': code.trim(),
        'device_id': await _deviceId(),
        ...metadata.toRequestFields(),
        if (captcha != null) ...captcha.toBodyFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException('注册响应无效');
      }
      await _saveAuth(token.toString(), data);
      final notice = data['registration_notice']?.toString().trim() ?? '';
      return notice.isEmpty ? null : _userFacingMessage(notice);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, '注册失败'));
      return null;
    }
  }

  /// 从目标服务器刷新当前用户资料，避免审核通过后的昵称/头像长期停留在旧缓存。
  Future<void> refreshProfile() async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) return;
    final data = await _requestAction('get_user_info', {
      'xymusic_id': xymusicId,
    }, fetchTimeoutMs: 15000);
    await _replaceStoredUser(AuthUser.fromJson(data));
  }

  /// 上传头像并提交审核。移动端先把图片缩放为 256px JPEG，
  /// 与电脑版保持相同的审核接口和体积限制。
  Future<String> uploadAvatar(Uint8List bytes) async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) {
      throw AuthException('请先登录');
    }
    if (bytes.isEmpty) throw AuthException('请选择有效的图片');

    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw AuthException('图片读取失败，请更换图片');
    final source = img.bakeOrientation(decoded);
    final maxSide = source.width > source.height ? source.width : source.height;
    final resized = maxSide > 256
        ? img.copyResize(
            source,
            width: source.width >= source.height
                ? 256
                : (source.width * 256 / source.height).round(),
            height: source.height >= source.width
                ? 256
                : (source.height * 256 / source.width).round(),
            interpolation: img.Interpolation.average,
          )
        : source;

    var quality = 80;
    var encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    while (encoded.length > 135 * 1024 && quality > 35) {
      quality -= 10;
      encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    }
    final avatarData = 'data:image/jpeg;base64,${base64Encode(encoded)}';
    if (avatarData.length > 195 * 1024) {
      throw AuthException('图片压缩后仍然过大，请选择更简单的图片');
    }

    final data = await _requestAction('upload_avatar', {
      'xymusic_id': xymusicId,
      'avatar_data': avatarData,
    }, fetchTimeoutMs: 55000);
    final status = data['status']?.toString().trim().toLowerCase() ?? '';
    if (status == 'approved') {
      await refreshProfile();
      return '头像已通过审核并生效';
    }
    return '头像已上传，等待管理员审核';
  }

  /// 查询当前头像审核状态：none / pending / rejected。
  Future<String> fetchAvatarStatus() async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) return 'none';
    final data = await _requestAction('get_avatar_status', {
      'xymusic_id': xymusicId,
    }, fetchTimeoutMs: 15000);
    final status = data['status']?.toString().trim().toLowerCase() ?? 'none';
    return switch (status) {
      'pending' => 'pending',
      'rejected' => 'rejected',
      _ => 'none',
    };
  }

  /// 提交昵称修改。服务端可能立即机审通过，也可能进入人工审核。
  Future<String> updateNickname(String nickname) async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) throw AuthException('请先登录');
    if (nickname.trim().isEmpty) throw AuthException('昵称不能为空');
    final token = await _storedToken();
    final data = await _requestAction('update_profile', {
      'token': token,
      'xymusic_id': xymusicId,
      'username': nickname.trim(),
      'nickname': nickname.trim(),
      'avatar': '',
    });
    final status = data['status']?.toString() ?? '';
    if (status == 'approved') {
      await refreshProfile();
      return '昵称已修改';
    }
    return status == 'pending' ? '昵称已提交审核' : '昵称修改已提交';
  }

  /// 修改当前账号密码。
  Future<String> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final xymusicId = state.user?.xymusicId?.trim() ?? '';
    if (xymusicId.isEmpty) throw AuthException('请先登录');
    if (newPassword.length < 6) throw AuthException('新密码长度不能少于 6 位');
    await _requestAction('change_password', {
      'xymusic_id': xymusicId,
      'old_password': oldPassword,
      'new_password': newPassword,
    });
    return '密码修改成功';
  }

  /// 使用邮箱验证码找回密码。
  Future<String> resetPassword({
    required String email,
    required String code,
    required String newPassword,
    HumanCaptchaPayload? captcha,
  }) async {
    if (newPassword.length < 6) throw AuthException('新密码长度不能少于 6 位');
    await _requestAction('reset_password', {
      'email': email.trim(),
      'verify_code': code.trim(),
      'new_password': newPassword,
      if (captcha != null) ...captcha.toBodyFields(),
    });
    return '密码修改成功，请使用新密码登录';
  }

  Future<String> _storedToken() async {
    final raw = await authGetCredentials(dataDir: await _dataDir());
    if (raw.trim().isEmpty || raw == 'null') return '';
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return '';
    return decoded['token']?.toString() ?? '';
  }

  Future<void> _replaceStoredUser(AuthUser user) async {
    final token = await _storedToken();
    if (token.isEmpty) throw AuthException('登录状态已失效，请重新登录');
    await authSaveCredentials(
      dataDir: await _dataDir(),
      token: token,
      userJson: jsonEncode(user.toJson()),
    );
    state = AuthState(user: user);
  }

  /// 设置内联错误信息（供 UI 展示本地校验错误，如两次密码不一致）。
  void setError(String message) {
    state = state.copyWith(loading: false, error: message);
  }

  /// 清除内联错误（切换登录/注册页时调用）。
  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
  }

  /// 退出登录（仅清理本地凭证）。
  Future<void> logout() async {
    try {
      final dir = await _dataDir();
      await authClearCredentials(dataDir: dir);
    } catch (_) {}
    state = const AuthState();
  }

  /// 提交问题反馈或功能建议，支持附加日志和图片 data URL。
  Future<int> submitFeedback({
    required String content,
    String feedbackType = 'problem',
    String? title,
    String? errorLogs,
    String? allLogs,
    List<String> images = const [],
  }) async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) {
      throw AuthException('请先登录账号后再提交反馈');
    }
    final type = feedbackType == 'suggestion' ? 'suggestion' : 'problem';
    final data = await _requestAction('submit_feedback', {
      'xymusic_id': xymusicId,
      'nickname': current.nickname.trim(),
      'title': (title?.trim().isNotEmpty == true)
          ? title!.trim()
          : (type == 'suggestion' ? '功能建议' : '问题反馈'),
      'content': content.trim(),
      'feedback_type': type,
      if (errorLogs?.trim().isNotEmpty == true) 'error_logs': errorLogs,
      if (allLogs?.trim().isNotEmpty == true) 'all_logs': allLogs,
      if (images.isNotEmpty) 'images': images,
    }, fetchTimeoutMs: 55000);
    return (data['id'] as num?)?.toInt() ?? int.tryParse('${data['id']}') ?? 0;
  }

  /// 获取当前账号的反馈记录及处理结果。
  Future<List<UserFeedbackItem>> listMyFeedback() async {
    final current = state.user;
    final xymusicId = current?.xymusicId?.trim() ?? '';
    if (current == null || xymusicId.isEmpty) {
      throw AuthException('请先登录账号后再查看反馈');
    }
    final data = await _requestAction('list_my_feedback', {
      'xymusic_id': xymusicId,
    }, fetchTimeoutMs: 20000);
    final list = data['list'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map(
          (item) => UserFeedbackItem.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList();
  }

  String _msg(Object e, String fallback) {
    if (e is AuthException) return _userFacingMessage(e.message);
    final s = e.toString();
    if (s.contains('network') || s.contains('Failed to fetch')) {
      return '网络异常，请检查网络连接';
    }
    if (s.contains('timeout')) return '请求超时，请稍后重试';
    return fallback;
  }

  /// 服务端返回的提示文案直接使用 XY Music 的统一称呼。
  String _userFacingMessage(String message) => message;
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref),
);
