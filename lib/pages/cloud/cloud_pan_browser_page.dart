import '../../src/cloud/cloud_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/player/cloud_play_context.dart';
import '../../src/player/player_provider.dart';

/// 网盘浏览页：我的网盘目录浏览 + 点播音频文件。
///
/// 路径语义各盘不同（fid / 真实路径 / folderId），导航键取
/// 「条目 path 非空且不等于当前目录时用 path，否则用 id」——覆盖
/// path 型盘（百度）与 id 型盘（其余）两种声明。
class CloudPanBrowserPage extends ConsumerStatefulWidget {
  const CloudPanBrowserPage({
    super.key,
    required this.providerId,
    this.accountId,
    this.selectRoot = false,
  });

  final String providerId;

  /// 指定账号 id；缺省取该盘第一个已绑定账号。
  final String? accountId;

  /// 目录选择模式：进入后浏览目录，点「设为歌曲目录」保存当前目录。
  /// 目录选择后浏览/播放只拉取该目录内的歌曲，不做全网盘扫描。
  final bool selectRoot;

  @override
  ConsumerState<CloudPanBrowserPage> createState() => _CloudBrowserPageState();
}

class _Crumb {
  const _Crumb(this.path, this.name);
  final String path;
  final String name;
}

class _CloudBrowserPageState extends ConsumerState<CloudPanBrowserPage> {
  late final CloudProvider _provider;
  List<CloudAccount> _accounts = const [];
  String? _accountId;
  bool _noAccount = false;

  final List<_Crumb> _stack = [];
  List<CloudFile> _files = const [];
  String? _cursor;
  bool _loading = true;
  bool _appending = false;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _init();
  }

  Future<void> _init() async {
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(_provider.id);
    if (!mounted) return;
    if (accounts.isEmpty) {
      setState(() {
        _noAccount = true;
        _loading = false;
      });
      return;
    }
    final id = widget.accountId ??
        accounts.first.accountId; // 传入账号已解绑时回退第一个
    final valid = accounts.any((a) => a.accountId == id)
        ? id
        : accounts.first.accountId;
    final account = accounts.firstWhere((a) => a.accountId == valid);
    // 目录选择模式从网盘根开始浏览；否则定位到已持久化的歌曲目录，
    // 保证“只拉取所选目录内歌曲，不做全网盘扫描”。
    final rootDir = widget.selectRoot ? null : account.rootDir;
    setState(() {
      _accounts = accounts;
      _accountId = valid;
      _stack
        ..clear()
        ..add(_Crumb(
          rootDir ?? _provider.rootPath,
          rootDir == null ? cloudT('全部文件') : cloudT('歌曲目录'),
        ));
    });
    _load();
  }

  Future<Map<String, String>> _cred() async {
    final id = _accountId;
    if (id != null) {
      final cred = await CloudCredentialsStore.instance.credFor(_provider.id, id);
      if (cred != null) return cred;
    }
    final sole = await CloudCredentialsStore.instance.soleCredFor(_provider.id);
    return sole ?? const {};
  }

  /// 进入子目录：path 型盘条目携带绝对路径，id 型盘回退用 id。
  void _enter(CloudFile dir) {
    final cur = _stack.last.path;
    final next = (dir.path != null &&
            dir.path!.isNotEmpty &&
            dir.path != cur)
        ? dir.path!
        : dir.id;
    setState(() => _stack.add(_Crumb(next, dir.name)));
    _load();
  }

  void _jumpTo(int index) {
    if (index == _stack.length - 1) return;
    setState(() => _stack.removeRange(index + 1, _stack.length));
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_cursor == null || _appending)) return;
    final path = _stack.last.path;
    if (!mounted) return;
    setState(() {
      if (more) {
        _appending = true;
      } else {
        _loading = true;
        _files = const [];
        _cursor = null;
      }
    });
    try {
      final cred = await _cred();
      final r = await _provider.listDir(cred, path, cursor: more ? _cursor : null);
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _files = more ? [..._files, ...r.files] : r.files;
        _cursor = r.nextCursor;
        _loading = false;
        _appending = false;
      });
    } catch (e) {
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _loading = false;
        _appending = false;
      });
      showXianYuToast(
        context,
        // 非 CloudException 多为解析期异常；透出原始信息，避免只看到兜底文案
        // 而无法定位（记忆约定：错误提示要带详细信息）。
        e is CloudException ? e.message : '${cloudT('目录加载失败')}（$e）',
      );
    }
  }

  Future<void> _switchAccount(String id) async {
    if (id == _accountId) return;
    final account = _accounts.firstWhere(
      (a) => a.accountId == id,
      orElse: () => _accounts.first,
    );
    // 切换账号后同样只定位到该账号已选择的歌曲目录。
    final rootDir = widget.selectRoot ? null : account.rootDir;
    setState(() {
      _accountId = id;
      _stack
        ..clear()
        ..add(_Crumb(
          rootDir ?? _provider.rootPath,
          rootDir == null ? cloudT('全部文件') : cloudT('歌曲目录'),
        ));
    });
    _load();
  }

  String? _currentRootDir() {
    for (final a in _accounts) {
      if (a.accountId == _accountId) return a.rootDir;
    }
    return null;
  }

  /// 快捷回到已选择的歌曲目录（仅浏览模式且已设置目录时）。
  void _jumpToRootDir() {
    final root = _currentRootDir();
    if (root == null || root.isEmpty) return;
    setState(() {
      _stack
        ..clear()
        ..add(_Crumb(root, cloudT('歌曲目录')));
    });
    _load();
  }

  /// 目录选择模式：把当前目录持久化为该账号的歌曲目录并返回。
  Future<void> _saveRootDir() async {
    final id = _accountId;
    if (id == null) return;
    final dir = _stack.last.path;
    await CloudCredentialsStore.instance.updateRootDir(_provider.id, id, dir);
    if (!mounted) return;
    showXianYuToast(context, cloudT('已设为歌曲目录'));
    Navigator.of(context).pop(true);
  }

  String _sizeText(int size) {
    if (size <= 0) return '';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _play(CloudFile f) async {
    CloudAccount? account;
    for (final a in _accounts) {
      if (a.accountId == _accountId) {
        account = a;
        break;
      }
    }
    if (account == null) {
      showXianYuToast(context, cloudT('网盘账号未绑定或已失效'));
      return;
    }
    final ctx = CloudPlayContext(
      provider: _provider.id,
      accountId: account.accountId,
      file: f,
    );
    await ref
        .read(playerProvider.notifier)
        .playQueue([cloudPlayQueueItem(ctx, artist: _provider.displayName)],
            startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rootDir = widget.selectRoot ? null : _currentRootDir();
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Column(
            children: [
              SizedBox(height: GlassTopBar.height(context)),
              if (_accounts.length > 1) _accountSelector(context, scheme),
              if (widget.selectRoot)
                _selectHint(context, scheme)
              else if (rootDir != null && rootDir.isNotEmpty)
                _rootDirHint(context, scheme, rootDir),
              _breadcrumb(context, scheme),
              Divider(
                height: 1,
                thickness: 0.5,
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
              Expanded(child: _list(context, scheme)),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(_provider.displayName),
              actions: [
                if (widget.selectRoot)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.tonal(
                      onPressed: _saveRootDir,
                      child: Text(cloudT('设为歌曲目录')),
                    ),
                  )
                else if (rootDir != null && rootDir.isNotEmpty)
                  IconButton(
                    onPressed: _jumpToRootDir,
                    icon: const Icon(Icons.folder_special_rounded),
                    tooltip: cloudT('歌曲目录'),
                  ),
              ],
            ),
          ),
          if (_noAccount) _noAccountView(context, scheme),
        ],
      ),
    );
  }

  Widget _selectHint(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              cloudT('进入您的歌曲目录后点右上角「设为歌曲目录」，之后只拉取该目录内的歌曲'),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rootDirHint(BuildContext context, ColorScheme scheme, String root) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          Icon(Icons.folder_special_rounded, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              cloudT('仅浏览歌曲目录：{path}', {'path': root}),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountSelector(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Text(
            cloudT('账号'),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              value: _accountId,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final a in _accounts)
                  DropdownMenuItem(
                    value: a.accountId,
                    child: Text(
                      a.nickname.isEmpty ? a.accountId : a.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _switchAccount(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumb(BuildContext context, ColorScheme scheme) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shrinkWrap: true,
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _stack.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  GestureDetector(
                    onTap: () => _jumpTo(i),
                    child: Text(
                      _stack[i].name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            i == _stack.length - 1 ? FontWeight.w600 : null,
                        color: i == _stack.length - 1
                            ? scheme.onSurface
                            : scheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty) {
      return Center(
        child: Text(
          cloudT('空目录'),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    final dirs = _files.where((f) => f.isDir).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final audio = _files.where((f) => !f.isDir && f.isAudio).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final others = _files
        .where((f) => !f.isDir && !f.isAudio)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final ordered = [...dirs, ...audio, ...others];

    return ListView.builder(
      itemCount: ordered.length + (_cursor != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= ordered.length) {
          return ListTile(
            title: Center(
              child: _appending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      cloudT('加载更多'),
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.primary,
                      ),
                    ),
            ),
            onTap: _appending ? null : () => _load(more: true),
          );
        }
        final f = ordered[i];
        final playable = f.isDir || f.isAudio;
        return ListTile(
          leading: Icon(
            f.isDir
                ? Icons.folder_rounded
                : (f.isAudio
                    ? Icons.music_note_rounded
                    : Icons.insert_drive_file_rounded),
            size: 22,
            color: f.isDir
                ? scheme.primary
                : (f.isAudio
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.4)),
          ),
          title: Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: playable
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ),
          subtitle: f.isDir || f.size <= 0
              ? null
              : Text(
                  _sizeText(f.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
          trailing: !f.isDir && f.isAudio
              ? Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: scheme.primary,
                )
              : null,
          onTap: () {
            if (f.isDir) {
              _enter(f);
            } else if (f.isAudio) {
              _play(f);
            }
          },
        );
      },
    );
  }

  Widget _noAccountView(BuildContext context, ColorScheme scheme) {
    return Positioned.fill(
      child: ColoredBox(
        color: scheme.surface.withValues(alpha: 0.96),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                cloudT('尚未绑定{name}', {'name': _provider.displayName}),
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.push('/cloud-bind'),
                child: Text(cloudT('去绑定')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
