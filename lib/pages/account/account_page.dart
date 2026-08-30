import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/sync/account_cloud_sync.dart';
import '../../src/widgets/top_notice.dart';
import '../../src/widgets/user_avatar_image.dart';

/// 账号认证页：未登录时展示登录/注册，已登录时展示个人资料。
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key, this.showSidebarButton = true});

  final bool showSidebarButton;

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _nicknameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _obscure = true;
  int _countdown = 0;
  bool _avatarUploading = false;
  String _avatarStatus = 'none';
  bool _cloudSyncing = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // 切换登录/注册时清空内联错误，避免旧错误残留。
    _tab.addListener(() {
      if (_tab.indexIsChanging) {
        ref.read(authProvider.notifier).clearError();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncProfile());
  }

  @override
  void dispose() {
    _tab.dispose();
    _nicknameCtrl.dispose();
    _idCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    Future.doWhile(() async {
      if (_countdown <= 0) return false;
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _countdown--);
      return true;
    });
  }

  Future<void> _sendCode() async {
    final email = _emailCtrl.text.trim();
    if (!email.contains('@')) {
      _toast('请输入正确的邮箱');
      return;
    }
    // 发送验证码前先过人机验证。
    final captcha = await _requestHumanCaptcha(
      title: '发送验证码前验证',
      description: '完成验证后将向邮箱发送注册验证码。',
    );
    if (captcha == null || !mounted) return;
    final notifier = ref.read(authProvider.notifier);
    try {
      final msg = await notifier.sendCode(email, 'register', captcha: captcha);
      if (!mounted) return;
      _toast(msg);
      if (msg.toLowerCase().contains('失败') || msg.contains('错误')) return;
      _startCountdown();
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '验证码发送失败');
    }
  }

  void _toast(String msg) {
    XyNotice.show(context, message: msg, duration: const Duration(seconds: 2));
  }

  Future<void> _submit() async {
    final notifier = ref.read(authProvider.notifier);
    final isLogin = _tab.index == 0;

    // 注册时先做本地密码一致性校验，避免无谓的人机验证。
    if (!isLogin && _passwordCtrl.text != _confirmCtrl.text) {
      notifier.setError('两次输入的密码不一致');
      return;
    }

    // 注册仍需人机验证；登录完全不请求、不弹出也不提交人机验证字段。
    HumanCaptchaPayload? captcha;
    if (!isLogin) {
      captcha = await _requestHumanCaptcha(
        title: '注册前验证',
        description: '完成验证后将继续创建账号。',
      );
      if (captcha == null || !mounted) return;
    }

    if (isLogin) {
      await notifier.login(
        xymusicId: _idCtrl.text,
        password: _passwordCtrl.text,
      );
    } else {
      final notice = await notifier.register(
        xymusicId: _idCtrl.text,
        nickname: _nicknameCtrl.text,
        password: _passwordCtrl.text,
        email: _emailCtrl.text,
        code: _codeCtrl.text,
        captcha: captcha,
      );
      if (notice != null && mounted) _toast(notice);
    }
    if (ref.read(authProvider).isLoggedIn) {
      await _loadAvatarStatus();
      if (isLogin) await _handleCloudSyncAfterLogin();
    }
    // 错误已通过 authProvider.error 反映到内联错误条，无需再弹 SnackBar。
  }

  Future<void> _forgotPassword() async {
    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('找回密码'),
        content: TextField(
          controller: emailCtrl,
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '注册邮箱',
            prefixIcon: Icon(Icons.mail_outline),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, emailCtrl.text.trim()),
            child: const Text('发送验证码'),
          ),
        ],
      ),
    );
    emailCtrl.dispose();
    if (email == null || !email.contains('@') || !mounted) return;

    final sendCaptcha = await _requestHumanCaptcha(
      title: '发送验证码前验证',
      description: '完成验证后将向注册邮箱发送找回密码验证码。',
    );
    if (sendCaptcha == null || !mounted) return;
    try {
      await ref
          .read(authProvider.notifier)
          .sendCode(email, 'reset_password', captcha: sendCaptcha);
      if (!mounted) return;
      _toast('验证码已发送，请查收邮件');
    } catch (error) {
      if (mounted) _toast(error.toString());
      return;
    }

    final codeCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置新密码'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '邮箱验证码'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认新密码'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, [
              codeCtrl.text.trim(),
              passwordCtrl.text,
              confirmCtrl.text,
            ]),
            child: const Text('重置密码'),
          ),
        ],
      ),
    );
    codeCtrl.dispose();
    passwordCtrl.dispose();
    confirmCtrl.dispose();
    if (values == null || !mounted) return;
    if (values[1] != values[2]) {
      _toast('两次输入的密码不一致');
      return;
    }
    final resetCaptcha = await _requestHumanCaptcha(
      title: '重置密码前验证',
      description: '完成最后一次验证后将修改账号密码。',
    );
    if (resetCaptcha == null || !mounted) return;
    try {
      final message = await ref
          .read(authProvider.notifier)
          .resetPassword(
            email: email,
            code: values[0],
            newPassword: values[1],
            captcha: resetCaptcha,
          );
      if (mounted) _toast(message);
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _editNickname() async {
    final current = ref.read(authProvider).user;
    if (current == null) return;
    final controller = TextEditingController(text: current.nickname);
    final nickname = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(labelText: '新昵称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nickname == null || nickname.isEmpty || !mounted) return;
    try {
      final message = await ref
          .read(authProvider.notifier)
          .updateNickname(nickname);
      if (mounted) _toast(message);
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _changePassword() async {
    final oldCtrl = TextEditingController();
    final nextCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '原密码'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nextCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码（至少 6 位）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认新密码'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, [
              oldCtrl.text,
              nextCtrl.text,
              confirmCtrl.text,
            ]),
            child: const Text('确认修改'),
          ),
        ],
      ),
    );
    oldCtrl.dispose();
    nextCtrl.dispose();
    confirmCtrl.dispose();
    if (values == null || !mounted) return;
    if (values[1] != values[2]) {
      _toast('两次输入的新密码不一致');
      return;
    }
    try {
      final message = await ref
          .read(authProvider.notifier)
          .changePassword(oldPassword: values[0], newPassword: values[1]);
      if (mounted) _toast(message);
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  Future<void> _refreshProfile() async {
    try {
      await _syncProfile();
      if (mounted) _toast('资料已刷新');
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  /// 进入账号页和手动刷新时都从服务端拉取最新资料。
  /// 头像人工审核通过后，旧的本地凭证不能继续作为唯一数据源。
  Future<void> _syncProfile() async {
    if (!ref.read(authProvider).isLoggedIn) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final auth = ref.read(authProvider.notifier);
    final playlists = ref.read(playlistsProvider.notifier);
    try {
      await auth.refreshProfile();
    } catch (_) {
      // 网络暂时不可用时保留本地资料，头像状态仍可单独查询。
    }
    await _loadAvatarStatus();
    if (!mounted) return;
    await AccountCloudSync.startAutoUpload(
      auth,
      playlists,
      container,
      favorites: ref.read(favoritesProvider.notifier),
    );
  }

  Future<void> _loadAvatarStatus() async {
    if (!mounted || !ref.read(authProvider).isLoggedIn) return;
    try {
      final status = await ref.read(authProvider.notifier).fetchAvatarStatus();
      if (mounted) setState(() => _avatarStatus = status);
    } catch (_) {
      // 状态查询失败不影响账号页面和头像显示。
    }
  }

  Future<void> _handleCloudSyncAfterLogin() async {
    final accountId = ref.read(authProvider).user?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty || !mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (await AccountCloudSync.isEnabled(accountId)) {
      await _runCloudSync();
      await AccountCloudSync.startAutoUpload(
        ref.read(authProvider.notifier),
        ref.read(playlistsProvider.notifier),
        container,
        favorites: ref.read(favoritesProvider.notifier),
      );
      return;
    }
    if (await AccountCloudSync.hasPrompted(accountId) || !mounted) return;
    final enabled = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CloudSyncPromptDialog(),
    );
    if (enabled == null) return;
    await AccountCloudSync.markPrompted(accountId);
    await AccountCloudSync.setEnabled(accountId, enabled);
    if (enabled && mounted) {
      await _runCloudSync();
      await AccountCloudSync.startAutoUpload(
        ref.read(authProvider.notifier),
        ref.read(playlistsProvider.notifier),
        container,
        favorites: ref.read(favoritesProvider.notifier),
      );
    }
  }

  Future<void> _runCloudSync() async {
    if (_cloudSyncing || !mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _cloudSyncing = true);
    try {
      final auth = ref.read(authProvider.notifier);
      final playlists = ref.read(playlistsProvider.notifier);
      final result = await AccountCloudSync.syncAll(
        auth,
        playlists,
        container,
        favorites: ref.read(favoritesProvider.notifier),
      );
      if (mounted) {
        final suffix = result.pluginErrors.isEmpty
            ? ''
            : '；插件失败 ${result.pluginErrors.length} 个，请稍后重试';
        _toast(
          result.noChange
              ? '云同步完成：歌单和插件没有变化，未重复上传$suffix'
              : '云同步完成：插件下载 ${result.downloadedPlugins} 个、上传 ${result.uploadedPlugins} 个；歌单上传 ${result.uploadedPlaylists} 个、下载 ${result.downloadedPlaylists} 个$suffix',
        );
      }
    } catch (error) {
      if (mounted) {
        _toast(
          error is AuthException ? '云同步失败：${error.message}' : '云同步失败：$error',
        );
      }
    } finally {
      if (mounted) setState(() => _cloudSyncing = false);
    }
  }

  Future<void> _pickAvatar() async {
    if (_avatarUploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final bytes = result.files.single.bytes;
    if (bytes == null || bytes.isEmpty) {
      _toast('无法读取图片，请重新选择');
      return;
    }
    if (bytes.length > 5 * 1024 * 1024) {
      _toast('头像不能超过 5MB');
      return;
    }
    setState(() => _avatarUploading = true);
    try {
      final message = await ref.read(authProvider.notifier).uploadAvatar(bytes);
      if (!mounted) return;
      setState(
        () => _avatarStatus = message.contains('等待') ? 'pending' : 'none',
      );
      _toast(message);
    } catch (error) {
      if (!mounted) return;
      await _loadAvatarStatus();
      _toast(error is AuthException ? error.message : '头像上传失败');
    } finally {
      if (mounted) setState(() => _avatarUploading = false);
    }
  }

  /// 弹出人机验证弹窗，返回验证通过的 payload；取消返回 null。
  Future<HumanCaptchaPayload?> _requestHumanCaptcha({
    required String title,
    required String description,
  }) {
    return showDialog<HumanCaptchaPayload>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HumanCaptchaDialog(
        title: title,
        description: description,
        notifier: ref.read(authProvider.notifier),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.showSidebarButton || !sidebarOnRight,
        leading: widget.showSidebarButton && !sidebarOnRight
            ? const AppSidebarMenuButton()
            : widget.showSidebarButton
            ? null
            : const BackButton(),
        title: Text(auth.isLoggedIn ? '我的' : '账号'),
        centerTitle: true,
        actions: [
          if (widget.showSidebarButton && sidebarOnRight)
            const AppSidebarMenuButton(),
        ],
      ),
      body: auth.isLoggedIn
          ? _ProfileView(
              user: auth.user!,
              onRefresh: _refreshProfile,
              onEditAvatar: _pickAvatar,
              avatarUploading: _avatarUploading,
              avatarStatus: _avatarStatus,
              onEditNickname: _editNickname,
              onChangePassword: _changePassword,
              onCloudSync: () => context.push('/account/cloud-sync'),
              cloudSyncing: _cloudSyncing,
              onLogout: () => _confirmLogout(context),
            )
          : _buildAuthForm(context, auth),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final router = GoRouter.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      AccountCloudSync.stopAutoUpload();
      await ref.read(authProvider.notifier).logout();
      // 从侧边栏直达账号页时，退出登录只应清空账号状态，不应让外层 StatefulShell 把路由切回设置。
      // 显式保持在账号页，让用户可直接切换到登录/注册。
      if (mounted) {
        router.go(
          widget.showSidebarButton ? '/account' : '/account?from=settings',
        );
      }
    }
  }

  Widget _buildAuthForm(BuildContext context, AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 品牌头部
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      scheme.primary,
                      scheme.primary.withValues(alpha: 0.7),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.music_note,
                  size: 34,
                  color: scheme.onPrimary,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'XY Music',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                '登录后可在多端共享歌单等信息',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        // 分段式 Tab
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(4),
            child: TabBar(
              controller: _tab,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(9),
              ),
              labelColor: scheme.onPrimary,
              unselectedLabelColor: scheme.onSurfaceVariant,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              tabs: const [
                Tab(text: '登录'),
                Tab(text: '注册'),
              ],
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [_loginForm(context, auth), _registerForm(context, auth)],
          ),
        ),
      ],
    );
  }

  Widget _loginForm(BuildContext context, AuthState auth) {
    return _formScroll(
      children: [
        _field(_idCtrl, '账号', hint: '请输入账号', icon: Icons.tag),
        _field(
          _passwordCtrl,
          '密码',
          hint: '请输入密码',
          icon: Icons.lock,
          obscure: _obscure,
        ),
        _errorBanner(context, auth),
        _submitButton(context, auth, '登录'),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: auth.loading ? null : _forgotPassword,
            child: const Text('忘记密码？'),
          ),
        ),
      ],
    );
  }

  Widget _registerForm(BuildContext context, AuthState auth) {
    return _formScroll(
      children: [
        _field(_idCtrl, '账号', hint: '6-20 位数字/字母', icon: Icons.tag),
        _field(_nicknameCtrl, '昵称（可选）', hint: '留空使用默认昵称', icon: Icons.badge),
        _field(
          _passwordCtrl,
          '密码',
          hint: '设置登录密码',
          icon: Icons.lock,
          obscure: _obscure,
        ),
        _field(
          _confirmCtrl,
          '确认密码',
          hint: '再次输入密码',
          icon: Icons.lock,
          obscure: _obscure,
        ),
        _field(
          _emailCtrl,
          '邮箱',
          hint: '用于接收验证码',
          icon: Icons.mail,
          keyboard: TextInputType.emailAddress,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                _codeCtrl,
                '邮箱验证码',
                hint: '请输入验证码',
                icon: Icons.verified,
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _countdown > 0 ? null : _sendCode,
                  child: Text(_countdown > 0 ? '${_countdown}s' : '发送验证码'),
                ),
              ),
            ),
          ],
        ),
        _errorBanner(context, auth),
        _submitButton(context, auth, '注册'),
      ],
    );
  }

  Widget _formScroll({required List<Widget> children}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [...children, const SizedBox(height: 8)],
      ),
    );
  }

  /// 内联错误条：登录/注册失败时在提交按钮上方显示，不会一闪而过。
  Widget _errorBanner(BuildContext context, AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    final error = auth.error;
    if (error == null || error.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String? hint,
    IconData? icon,
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboard,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          suffixIcon: obscure
              ? IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                )
              : null,
        ),
      ),
    );
  }

  Widget _submitButton(BuildContext context, AuthState auth, String label) {
    return FilledButton(
      onPressed: auth.loading ? null : _submit,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: auth.loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
    );
  }
}

/// 已登录资料视图。
class _ProfileView extends StatelessWidget {
  const _ProfileView({
    required this.user,
    required this.onRefresh,
    required this.onEditAvatar,
    required this.avatarUploading,
    required this.avatarStatus,
    required this.onEditNickname,
    required this.onChangePassword,
    required this.onCloudSync,
    required this.cloudSyncing,
    required this.onLogout,
  });
  final AuthUser user;
  final VoidCallback onRefresh;
  final VoidCallback onEditAvatar;
  final bool avatarUploading;
  final String avatarStatus;
  final VoidCallback onEditNickname;
  final VoidCallback onChangePassword;
  final VoidCallback onCloudSync;
  final bool cloudSyncing;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
      children: [
        // 头像区：点击头像或右下角按钮即可提交新头像审核。
        Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                onTap: avatarUploading ? null : onEditAvatar,
                child: _Avatar(user: user),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Material(
                  color: scheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: avatarUploading ? null : onEditAvatar,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: avatarUploading
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          : Icon(
                              Icons.edit_rounded,
                              size: 16,
                              color: scheme.onPrimary,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            user.nickname.isEmpty ? '未命名用户' : user.nickname,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        if (user.role.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                user.role,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 32),
        // 信息分组卡
        _InfoCard(
          children: [
            _InfoTile(
              icon: Icons.mail_outline,
              label: '邮箱',
              value: user.email.isEmpty ? '未绑定' : user.email,
            ),
            if (user.xymusicId != null && user.xymusicId!.isNotEmpty)
              _InfoTile(icon: Icons.tag, label: '账号', value: user.xymusicId!),
          ],
        ),
        const SizedBox(height: 16),
        _InfoCard(
          children: [
            ListTile(
              leading: Icon(Icons.refresh_rounded, color: scheme.primary),
              title: const Text('刷新账号资料'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onRefresh,
            ),
            ListTile(
              leading: Icon(
                Icons.account_circle_outlined,
                color: scheme.primary,
              ),
              title: const Text('修改头像'),
              subtitle: Text(switch (avatarStatus) {
                'pending' => '头像审核中',
                'rejected' => '上次头像审核未通过，可重新提交',
                _ => '上传后将进入审核流程',
              }),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: avatarUploading ? null : onEditAvatar,
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: scheme.primary),
              title: const Text('修改昵称'),
              subtitle: const Text('修改后可能需要审核'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onEditNickname,
            ),
            ListTile(
              leading: Icon(Icons.lock_outline_rounded, color: scheme.primary),
              title: const Text('修改密码'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onChangePassword,
            ),
            ListTile(
              leading: Icon(Icons.cloud_sync_outlined, color: scheme.primary),
              title: const Text('账号云同步'),
              subtitle: Text(cloudSyncing ? '正在上传和同步歌单…' : '设置自动上传频率或手动同步'),
              trailing: cloudSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right_rounded),
              onTap: cloudSyncing ? null : onCloudSync,
            ),
          ],
        ),
        const SizedBox(height: 24),
        // 退出登录
        OutlinedButton.icon(
          onPressed: onLogout,
          icon: Icon(Icons.logout, color: scheme.error),
          label: Text('退出登录', style: TextStyle(color: scheme.error)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}

/// 头像：有网络头像则加载，否则用昵称首字符 + 主题色实心底占位。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.user});
  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = user.avatar;
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    final fallbackChar = user.nickname.isEmpty
        ? '?'
        : String.fromCharCode(user.nickname.runes.first);
    // 头像必须始终在一个正方形约束内按比例裁剪，否则服务端返回的
    // 竖图/横图会按自身尺寸参与布局，导致圆形框四周留白不一致。
    // 外层白色圆环固定为 3px，内层再单独裁成圆形，保证上下左右一致。
    return Container(
      width: 96,
      height: 96,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: SizedBox.expand(
          child: hasAvatar
              ? UserAvatarImage(
                  source: avatar,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      _fallback(fallbackChar, scheme.onPrimary),
                )
              : ColoredBox(
                  color: scheme.primary,
                  child: _fallback(fallbackChar, scheme.onPrimary),
                ),
        ),
      ),
    );
  }

  Widget _fallback(String char, Color color) {
    return Center(
      child: Text(
        char,
        style: TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

/// 信息分组卡片容器。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 在项之间插入分隔线。
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(Divider(height: 1, indent: 52, color: scheme.outlineVariant));
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: items),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(label),
      trailing: Text(value, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }
}

/// 登录成功后的账号云同步选择弹窗。
class _CloudSyncPromptDialog extends StatefulWidget {
  const _CloudSyncPromptDialog();

  @override
  State<_CloudSyncPromptDialog> createState() => _CloudSyncPromptDialogState();
}

class _CloudSyncPromptDialogState extends State<_CloudSyncPromptDialog> {
  Timer? _timer;
  int _remaining = 3;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _timer?.cancel();
        setState(() => _remaining = 0);
      } else {
        setState(() => _remaining--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _remaining == 0;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('是否启用账号云同步？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '开启后您可在多端共享歌单等信息',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '如您关闭，后续您可在账号页手动进行上传',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (!enabled) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                '请等待 $_remaining 秒后选择',
                style: TextStyle(fontSize: 13, color: scheme.primary),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: enabled ? () => Navigator.pop(context, false) : null,
          child: const Text('暂不上传'),
        ),
        FilledButton(
          onPressed: enabled ? () => Navigator.pop(context, true) : null,
          child: const Text('开启'),
        ),
      ],
    );
  }
}

/// 人机验证弹窗（内置算术题模式）。
/// 加载题目 → 输入答案 → 预校验通过后返回 [HumanCaptchaPayload]。
class _HumanCaptchaDialog extends StatefulWidget {
  const _HumanCaptchaDialog({
    required this.title,
    required this.description,
    required this.notifier,
  });
  final String title;
  final String description;
  final AuthNotifier notifier;

  @override
  State<_HumanCaptchaDialog> createState() => _HumanCaptchaDialogState();
}

class _HumanCaptchaDialogState extends State<_HumanCaptchaDialog> {
  final _answerCtrl = TextEditingController();
  HumanCaptcha? _captcha;
  bool _loading = false;
  bool _verifying = false;
  String? _error;
  int _refreshToken = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final refreshToken = ++_refreshToken;
    setState(() {
      _loading = true;
      _error = null;
      _answerCtrl.clear();
    });
    try {
      final c = await widget.notifier.fetchCaptcha();
      if (!mounted || refreshToken != _refreshToken) return;
      setState(() {
        _captcha = c;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || refreshToken != _refreshToken) return;
      setState(() {
        _captcha = null;
        _loading = false;
        _error = e is AuthException ? e.message : '验证题加载失败，请稍后重试';
      });
    }
  }

  Future<void> _submit() async {
    final captcha = _captcha;
    if (captcha == null || captcha.captchaId.isEmpty) {
      setState(() => _error = '请先加载验证题');
      return;
    }
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) {
      setState(() => _error = '请输入验证答案');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    final payload = HumanCaptchaPayload(
      captchaId: captcha.captchaId,
      captchaAnswer: answer,
    );
    try {
      await widget.notifier.verifyCaptcha(payload);
      if (!mounted) return;
      Navigator.pop(context, payload);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = e is AuthException ? e.message : '人机验证失败，请重试';
        _answerCtrl.clear();
      });
      // 验证失败后自动换一题（旧题可能已失效）。
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.description,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          // 题目区
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _loading
                        ? '正在加载验证题…'
                        : (_captcha?.question.isNotEmpty == true
                              ? _captcha!.question
                              : '验证题加载失败'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loading || _verifying ? null : _refresh,
                  child: Text(_loading ? '刷新中…' : '换一题'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _answerCtrl,
            keyboardType: TextInputType.number,
            autofocus: true,
            enabled: !_loading && !_verifying && _captcha != null,
            decoration: InputDecoration(
              labelText: '验证答案',
              hintText: '请输入答案',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null && _error!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(fontSize: 13, color: scheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _verifying ? null : () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_loading || _verifying || _captcha == null)
              ? null
              : _submit,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('验证并继续'),
        ),
      ],
    );
  }
}
