import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../src/music_platform/platform_api.dart';
import '../../src/music_platform/platform_session.dart';
import '../../src/widgets/top_notice.dart';
import 'web_login_page.dart';

/// 各平台通用的“网页登录”入口：推入 WebView 登录页，
/// 登录成功后由页面自行保存会话并返回。
Future<void> _showWebLogin(BuildContext context, MusicPlatform platform) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => WebLoginPage(platform: platform)),
  );
}

/// 第三方音乐平台账号页：QQ / 网易 / 酷狗登录后可拉取在线收藏歌单。
class PlatformAccountPage extends ConsumerWidget {
  const PlatformAccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(musicPlatformSessionsProvider);
    final accounts = sessions.valueOrNull?.accounts ?? const {};
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('第三方音乐平台'),
        centerTitle: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          Text(
            '登录后可拉取该账号的在线歌单并导入到本地。',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final platform in MusicPlatform.values)
            _PlatformCard(platform: platform, account: accounts[platform]),
        ],
      ),
    );
  }
}

class _PlatformCard extends ConsumerWidget {
  const _PlatformCard({required this.platform, this.account});

  final MusicPlatform platform;
  final MusicPlatformAccount? account;

  static (String, Color) _badge(MusicPlatform platform) => switch (platform) {
    MusicPlatform.netease => ('网', Color(0xFFD33A31)),
    MusicPlatform.qq => ('Q', Color(0xFF31C27C)),
    MusicPlatform.kugou => ('酷', Color(0xFF2CA8E8)),
  };

  static IconData _icon(MusicPlatform platform) => switch (platform) {
    MusicPlatform.netease => Icons.cloud_queue_rounded,
    MusicPlatform.qq => Icons.qr_code_2_rounded,
    MusicPlatform.kugou => Icons.key_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = _badge(platform);
    final account = this.account;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  platform.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  account == null
                      ? '未登录'
                      : '${account.nickname}（${account.userId}）',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (account == null)
            FilledButton.tonalIcon(
              onPressed: () => _startLogin(context),
              icon: Icon(_icon(platform)),
              label: const Text('登录'),
            )
          else ...[
            FilledButton.tonalIcon(
              onPressed: () => context.push(
                '/account/music-platform/playlists/${platform.name}',
              ),
              icon: const Icon(Icons.queue_music_rounded),
              label: const Text('我的歌单'),
            ),
            IconButton(
              tooltip: '退出登录',
              onPressed: () => _confirmLogout(context, ref),
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('退出${platform.label}'),
        content: const Text('确定要解除该平台的登录吗？已导入的本地歌单不受影响。'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(musicPlatformSessionsProvider.notifier).logout(platform);
  }

  void _startLogin(BuildContext context) {
    switch (platform) {
      case MusicPlatform.netease:
        _showNeteaseLogin(context);
      case MusicPlatform.qq:
        _showQqLogin(context);
      case MusicPlatform.kugou:
        _showKugouLogin(context);
    }
  }
}

// ---------------------------------------------------------------------------
// 网易云：二维码 + 手机号密码两种方式
// ---------------------------------------------------------------------------

Future<void> _showNeteaseLogin(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    // 挂到根 Navigator：账号页位于 AppShell（含自定义底栏/迷你播放条）
    // 的内层 Navigator 中，默认弹窗会被悬浮底栏盖住。
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => const _NeteaseLoginSheet(),
  );
}

class _NeteaseLoginSheet extends ConsumerStatefulWidget {
  const _NeteaseLoginSheet();

  @override
  ConsumerState<_NeteaseLoginSheet> createState() => _NeteaseLoginSheetState();
}

class _NeteaseLoginSheetState extends ConsumerState<_NeteaseLoginSheet> {
  final _api = NeteaseApi();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _byQr = true;
  bool _loading = false;
  bool _submitting = false;
  String? _error;

  String? _qrKey;
  Timer? _timer;
  // 801 等待扫码、802 已扫码待确认、803 成功。
  int _qrStatus = 0;

  @override
  void initState() {
    super.initState();
    _loadQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadQr() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _qrStatus = 0;
    });
    try {
      final key = await _api.createQrKey();
      if (!mounted) return;
      setState(() {
        _qrKey = key;
        _loading = false;
      });
      _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (!mounted || _qrKey == null) return;
        try {
          final result = await _api.checkQrLogin(_qrKey!);
          if (!mounted) return;
          if (result.code == 803 && result.cookies['MUSIC_U'] != null) {
            _timer?.cancel();
            final account = await _api.fetchAccount(result.cookies);
            await ref
                .read(musicPlatformSessionsProvider.notifier)
                .saveAccount(account);
            if (!mounted) return;
            Navigator.of(context).pop();
            XyNotice.show(
              context,
              message: '网易云登录成功：${account.nickname}',
              type: XyNoticeType.success,
            );
          } else if (result.code == 800) {
            if (!mounted) return;
            _timer?.cancel();
            setState(() => _error = '二维码已过期，请点击刷新');
          } else {
            setState(() => _qrStatus = result.code);
          }
        } on Exception {
          // 网络抖动时下一轮重试。
        }
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is PlatformApiException ? error.message : '网络异常，请稍后重试';
      });
    }
  }

  Future<void> _submitPhone() async {
    final phone = _phoneCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (phone.isEmpty || password.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await _api.loginByPhone(phone, password);
      final musicU = result.cookies['MUSIC_U'];
      if (musicU == null) {
        throw const PlatformApiException('登录响应缺少凭证，请改用扫码登录');
      }
      final account = await _api.fetchAccount(result.cookies);
      await ref
          .read(musicPlatformSessionsProvider.notifier)
          .saveAccount(account);
      if (!mounted) return;
      Navigator.of(context).pop();
      XyNotice.show(
        context,
        message: '网易云登录成功：${account.nickname}',
        type: XyNoticeType.success,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformApiException ? error.message : '$error',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '登录网易云音乐',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('扫码登录')),
                ButtonSegment(value: false, label: Text('手机号登录')),
              ],
              selected: {_byQr},
              onSelectionChanged: (selection) {
                setState(() => _byQr = selection.first);
                if (selection.first) _loadQr();
              },
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            if (_byQr)
              _buildQr(scheme)
            else
              _buildPhoneForm(scheme, keyboardOpen),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _showWebLogin(context, MusicPlatform.netease);
              },
              icon: const Icon(Icons.language_rounded),
              label: const Text('网页登录（扫码/手机验证码均可）'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQr(ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: _qrKey == null
              ? const SizedBox(width: 200, height: 200)
              : QrImageView(
                  data: 'https://music.163.com/login?codekey=$_qrKey',
                  size: 200,
                  backgroundColor: Colors.white,
                ),
        ),
        const SizedBox(height: 12),
        Text(switch (_qrStatus) {
          802 => '已扫码，请在手机上确认',
          _ => '打开网易云音乐 App 扫码登录',
        }, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _loadQr,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('刷新二维码'),
        ),
      ],
    );
  }

  Widget _buildPhoneForm(ColorScheme scheme, bool keyboardOpen) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: '手机号',
            prefixIcon: Icon(Icons.phone_iphone_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscure,
          onSubmitted: (_) => _submitPhone(),
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        SizedBox(height: keyboardOpen ? 12 : 20),
        FilledButton(
          onPressed: _submitting ? null : _submitPhone,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// QQ 音乐：微信 / QQ 扫码
// ---------------------------------------------------------------------------

Future<void> _showQqLogin(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    // 挂到根 Navigator，避免被自定义底栏遮挡（同网易登录）。
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => const _QqLoginSheet(),
  );
}

class _QqLoginSheet extends ConsumerStatefulWidget {
  const _QqLoginSheet();

  @override
  ConsumerState<_QqLoginSheet> createState() => _QqLoginSheetState();
}

class _QqLoginSheetState extends ConsumerState<_QqLoginSheet> {
  final _api = QqMusicApi();
  Timer? _timer;
  bool _loading = true;
  bool _byWx = true;
  String? _error;
  String? _uuid; // 微信：qrconnect uuid
  String? _qrsig; // QQ：ptqrshow qrsig
  String? _loginSig; // QQ：xlogin pt_login_sig
  Uint8List? _qrImage;
  // 微信：405 已确认、404 已扫码待确认、408 等待扫码、403 拒绝。
  // QQ：0 成功、66 等待扫码、67 已扫码待确认、68 过期。
  int _status = -1;

  @override
  void initState() {
    super.initState();
    _loadQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadQr() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _status = _byWx ? 408 : 66;
    });
    try {
      if (_byWx) {
        final result = await _api.createWxQr();
        if (!mounted) return;
        setState(() {
          _uuid = result.uuid;
          _qrsig = null;
          _qrImage = result.qrImage;
          _loading = false;
        });
      } else {
        final result = await _api.createQqQr();
        if (!mounted) return;
        setState(() {
          _uuid = null;
          _qrsig = result.qrsig;
          _loginSig = result.loginSig;
          _qrImage = result.qrImage;
          _loading = false;
        });
      }
      _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (!mounted) return;
        try {
          if (_byWx) {
            if (_uuid == null) return;
            await _pollWx();
          } else {
            if (_qrsig == null) return;
            await _pollQq();
          }
        } on Exception {
          // 网络抖动时下一轮重试。
        }
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is PlatformApiException ? error.message : '网络异常，请稍后重试';
      });
    }
  }

  Future<void> _pollWx() async {
    final status = await _api.checkWxLogin(_uuid!);
    if (!mounted) return;
    if (status.status == 405 && status.code.isNotEmpty) {
      _timer?.cancel();
      final account = await _api.wxLogin(status.code);
      await _saveAndClose(account);
    } else if (status.status == 403) {
      _timer?.cancel();
      setState(() => _error = '已取消授权，请重新扫码');
    } else {
      setState(() => _status = status.status);
    }
  }

  Future<void> _pollQq() async {
    final status = await _api.checkQqLogin(_qrsig!, _loginSig ?? '');
    if (!mounted) return;
    if (status.status == 0 && status.checkSigUrl.isNotEmpty) {
      _timer?.cancel();
      final account = await _api.qqQrLogin(status.checkSigUrl);
      await _saveAndClose(account);
    } else if (status.status == 68) {
      _timer?.cancel();
      setState(() => _error = '二维码已过期，请点击刷新');
    } else {
      setState(() => _status = status.status);
    }
  }

  Future<void> _saveAndClose(MusicPlatformAccount account) async {
    await ref.read(musicPlatformSessionsProvider.notifier).saveAccount(account);
    if (!mounted) return;
    Navigator.of(context).pop();
    XyNotice.show(
      context,
      message: 'QQ音乐登录成功：${account.nickname}',
      type: XyNoticeType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '登录QQ音乐',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('微信扫码')),
                ButtonSegment(value: false, label: Text('QQ扫码')),
              ],
              selected: {_byWx},
              onSelectionChanged: (selection) {
                setState(() => _byWx = selection.first);
                _loadQr();
              },
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_qrImage != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(_qrImage!, width: 220, height: 220),
              ),
            const SizedBox(height: 12),
            Text(
              _byWx
                  ? switch (_status) {
                      404 => '已扫码，请在微信上确认',
                      _ => '打开微信扫一扫，扫码授权登录',
                    }
                  : switch (_status) {
                      67 => '已扫码，请在手机QQ上确认',
                      _ => '打开手机QQ扫一扫，扫码授权登录',
                    },
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _loadQr,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('刷新二维码'),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _showWebLogin(context, MusicPlatform.qq);
              },
              icon: const Icon(Icons.language_rounded),
              label: const Text('网页登录（扫码/账密均可）'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 酷狗：扫码 / 短信验证码 / 账号密码
// ---------------------------------------------------------------------------

Future<void> _showKugouLogin(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    // 挂到根 Navigator，避免被自定义底栏遮挡（同网易登录）。
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => const _KugouLoginSheet(),
  );
}

class _KugouLoginSheet extends ConsumerStatefulWidget {
  const _KugouLoginSheet();

  @override
  ConsumerState<_KugouLoginSheet> createState() => _KugouLoginSheetState();
}

class _KugouLoginSheetState extends ConsumerState<_KugouLoginSheet> {
  final _api = KugouApi();
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _byQr = true;
  bool _bySms = false;
  bool _loading = false;
  bool _sendingCode = false;
  bool _submitting = false;
  String? _error;

  String? _qrKey;
  Uint8List? _qrImage;
  Timer? _timer;
  // 0 过期、1 等待扫码、2 已扫码待确认、4 授权成功。
  int _qrStatus = 1;

  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _loadQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _countdownTimer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadQr() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _qrStatus = 1;
    });
    try {
      final result = await _api.createQr();
      if (!mounted) return;
      setState(() {
        _qrKey = result.key;
        _qrImage = result.qrImage;
        _loading = false;
      });
      _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
        if (!mounted || _qrKey == null) return;
        try {
          final result = await _api.checkQrLogin(_qrKey!);
          if (!mounted) return;
          final account = result.account;
          if (result.status == 4 && account != null) {
            _timer?.cancel();
            await _saveAndClose(account);
          } else if (result.status == 0) {
            _timer?.cancel();
            setState(() => _error = '二维码已过期，请点击刷新');
          } else {
            setState(() => _qrStatus = result.status);
          }
        } on Exception {
          // 网络抖动时下一轮重试。
        }
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is PlatformApiException ? error.message : '网络异常，请稍后重试';
      });
    }
  }

  Future<void> _sendCode() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.length != 11 || _sendingCode) return;
    setState(() {
      _sendingCode = true;
      _error = null;
    });
    try {
      await _api.sendSmsCode(phone);
      if (!mounted) return;
      _startCountdown();
    } on Exception catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformApiException ? error.message : '$error',
      );
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_countdown <= 1) {
        _countdownTimer?.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown -= 1);
      }
    });
  }

  Future<void> _submitSms() async {
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (phone.length != 11 || code.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final account = await _api.loginBySmsCode(phone, code);
      await _saveAndClose(account);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformApiException ? error.message : '$error',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitPassword() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final account = await _api.loginByPassword(username, password);
      await _saveAndClose(account);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformApiException ? error.message : '$error',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _saveAndClose(MusicPlatformAccount account) async {
    await ref.read(musicPlatformSessionsProvider.notifier).saveAccount(account);
    if (!mounted) return;
    Navigator.of(context).pop();
    XyNotice.show(
      context,
      message: '酷狗登录成功：${account.nickname}',
      type: XyNoticeType.success,
    );
  }

  void _switchMode({required bool byQr, required bool bySms}) {
    setState(() {
      _byQr = byQr;
      _bySms = bySms;
      _error = null;
    });
    if (byQr) {
      _loadQr();
    } else {
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '登录酷狗音乐',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('扫码登录')),
                ButtonSegment(value: 1, label: Text('短信登录')),
                ButtonSegment(value: 2, label: Text('密码登录')),
              ],
              selected: {_byQr ? 0 : _bySms ? 1 : 2},
              onSelectionChanged: (selection) => _switchMode(
                byQr: selection.first == 0,
                bySms: selection.first == 1,
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            if (_byQr)
              _buildQr(scheme)
            else if (_bySms)
              _buildSmsForm(scheme, keyboardOpen)
            else
              _buildPasswordForm(scheme, keyboardOpen),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _showWebLogin(context, MusicPlatform.kugou);
              },
              icon: const Icon(Icons.language_rounded),
              label: const Text('网页登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQr(ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: _qrKey == null
              ? const SizedBox(width: 200, height: 200)
              : _qrImage != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(_qrImage!, width: 200, height: 200),
                )
              : QrImageView(
                  data:
                      'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=$_qrKey',
                  size: 200,
                  backgroundColor: Colors.white,
                ),
        ),
        const SizedBox(height: 12),
        Text(switch (_qrStatus) {
          2 => '已扫码，请在酷狗音乐 App 上确认',
          _ => '打开酷狗音乐 App 扫码登录',
        }, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _loadQr,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('刷新二维码'),
        ),
      ],
    );
  }

  Widget _buildSmsForm(ColorScheme scheme, bool keyboardOpen) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: '手机号',
            prefixIcon: Icon(Icons.phone_iphone_rounded),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _submitSms(),
                decoration: const InputDecoration(
                  labelText: '验证码',
                  prefixIcon: Icon(Icons.sms_rounded),
                ),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: _countdown > 0 || _sendingCode ? null : _sendCode,
              child: _sendingCode
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _countdown > 0 ? '${_countdown}s' : '获取验证码',
                      style: const TextStyle(fontSize: 13),
                    ),
            ),
          ],
        ),
        SizedBox(height: keyboardOpen ? 12 : 20),
        FilledButton(
          onPressed: _submitting ? null : _submitSms,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }

  Widget _buildPasswordForm(ColorScheme scheme, bool keyboardOpen) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _usernameCtrl,
          decoration: const InputDecoration(
            labelText: '手机号 / 邮箱 / 用户名',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          obscureText: _obscure,
          onSubmitted: (_) => _submitPassword(),
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            ),
          ),
        ),
        SizedBox(height: keyboardOpen ? 12 : 20),
        FilledButton(
          onPressed: _submitting ? null : _submitPassword,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
        const SizedBox(height: 6),
        Text(
          '账号密码仅用于本次登录并保存在本机，不会上传到任何服务器。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
