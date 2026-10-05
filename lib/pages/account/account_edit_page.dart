import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/widgets/top_notice.dart';

/// 编辑账号信息页：把修改头像、修改昵称、修改密码、刷新账号资料
/// 集中到一个独立页面（从「我的」页的单一入口进入）。
class AccountEditPage extends ConsumerStatefulWidget {
  const AccountEditPage({super.key});

  @override
  ConsumerState<AccountEditPage> createState() => _AccountEditPageState();
}

class _AccountEditPageState extends ConsumerState<AccountEditPage> {
  bool _avatarUploading = false;
  String _avatarStatus = 'none';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAvatarStatus());
  }

  void _toast(String msg) {
    if (!mounted) return;
    XyNotice.show(context, message: msg, duration: const Duration(seconds: 2));
  }

  Future<void> _loadAvatarStatus() async {
    if (!mounted || !ref.read(authProvider).isLoggedIn) return;
    try {
      final status = await ref.read(authProvider.notifier).fetchAvatarStatus();
      if (mounted) setState(() => _avatarStatus = status);
    } catch (_) {
      // 状态查询失败不影响页面展示。
    }
  }

  Future<void> _pickAvatar() async {
    if (_avatarUploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      // 禁用插件压缩：其原生实现写入公共 Pictures 目录，Android 10
      // 分区存储下无权限会直接崩溃。
      compressionQuality: 0,
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
      _toast(message);
    } catch (error) {
      _toast(error.toString());
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
      _toast(message);
    } catch (error) {
      _toast(error.toString());
    }
  }

  Future<void> _refreshProfile() async {
    try {
      await ref.read(authProvider.notifier).refreshProfile();
      await _loadAvatarStatus();
      _toast('资料已刷新');
    } catch (error) {
      _toast(error is AuthException ? error.message : error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑账号信息'), centerTitle: true),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          20,
          16,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          _InfoCard(
            children: [
              ListTile(
                leading: Icon(
                  Icons.account_circle_outlined,
                  color: scheme.primary,
                ),
                title: const Text('修改头像'),
                subtitle: Text(switch (_avatarStatus) {
                  'pending' => '头像审核中',
                  'rejected' => '上次头像审核未通过，可重新提交',
                  _ => '上传后将进入审核流程',
                }),
                trailing: _avatarUploading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right_rounded),
                onTap: _avatarUploading ? null : _pickAvatar,
              ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: scheme.primary),
                title: const Text('修改昵称'),
                subtitle: const Text('修改后可能需要审核'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _editNickname,
              ),
              ListTile(
                leading: Icon(Icons.lock_outline_rounded, color: scheme.primary),
                title: const Text('修改密码'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _changePassword,
              ),
              ListTile(
                leading: Icon(Icons.refresh_rounded, color: scheme.primary),
                title: const Text('刷新账号资料'),
                subtitle: const Text('从服务器拉取最新头像与资料'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _refreshProfile,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 信息分组卡片容器（与「我的」页同款样式）。
class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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