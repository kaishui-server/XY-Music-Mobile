import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/library/native_storage_permission.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/widgets/top_notice.dart';
import '../library/folder_browser_page.dart';

/// 扫描目录管理页：添加/删除本地音乐扫描目录。
class ScanFoldersPage extends ConsumerStatefulWidget {
  const ScanFoldersPage({super.key});

  @override
  ConsumerState<ScanFoldersPage> createState() => _ScanFoldersPageState();
}

class _ScanFoldersPageState extends ConsumerState<ScanFoldersPage> {
  bool _adding = false;

  void _toast(String msg) {
    if (!mounted) return;
    XyNotice.show(context, message: msg, duration: const Duration(seconds: 2));
  }

  Future<void> _addFolder() async {
    setState(() => _adding = true);
    try {
      // 权限走原生桥（MusicFree 同款），按系统版本申请真实所需权限。
      if (!await NativeStoragePermission.ensure()) {
        _toast(await NativeStoragePermission.deniedHint);
        return;
      }
      String? dir;
      if (Platform.isAndroid) {
        // 自建目录浏览器（MusicFree fileSelector 同款）：返回真实
        // 文件路径且与扫描走同一套权限。
        if (!mounted) return;
        dir = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const FolderBrowserPage()),
        );
      } else {
        dir = await FilePicker.platform.getDirectoryPath();
      }
      if (dir == null || dir.startsWith('content://')) return; // 用户取消
      // 非 Android（SAF 路径）校验可读性；Android 浏览器能列出即已可读。
      if (!Platform.isAndroid &&
          !await NativeStoragePermission.isReadableDirectory(dir)) {
        _toast('无法读取所选文件夹');
        return;
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(dir);
      // 添加即扫描（与 MusicFree 导入即扫一致）：不扫的话歌曲要等用户
      // 手动到音乐库下拉刷新才出现，看起来就像“文件夹加进来了但歌没进来”。
      _toast('已添加扫描目录，开始扫描...');
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        if (!mounted) return;
        if (count == 0) {
          // 权限已由扫描编排器预检过，这里 0 首就是目录里确实没有
          // 受支持格式的音频文件。
          _toast('已添加目录，但未扫描到歌曲，请确认目录内有受支持格式的音频文件');
        } else {
          _toast('已添加目录，共扫描到 $count 首歌曲');
        }
      } on Exception catch (e) {
        if (!mounted) return;
        _toast('扫描失败：${e.toString().replaceFirst('Exception: ', '')}');
      }
    } catch (e) {
      _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除扫描目录'),
        content: Text('确定移除该目录吗？\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(scanFoldersProvider.notifier).removeFolder(path);
      _toast('已移除');
    } catch (e) {
      _toast('移除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(scanFoldersProvider);
    final scheme = Theme.of(context).colorScheme;
    // 悬浮底栏 + 迷你播放栏固定占据底部条带（Shell 已把高度注入
    // MediaQuery.padding.bottom），页面底部两角/底部的按钮都会被遮挡，
    // 「添加目录」改为悬浮在页面正中央。
    final folders = foldersAsync.valueOrNull ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('扫描文件夹')),
      floatingActionButton: folders.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _adding ? null : _addFolder,
              icon: _adding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.create_new_folder),
              label: const Text('添加目录'),
            ),
      floatingActionButtonLocation: const _CenterFabLocation(),
      body: foldersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (folders) {
          if (folders.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_off,
                      size: 48,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '还没有扫描目录',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '点击「添加目录」选择本地音乐文件夹，\n然后到「音乐库 → 本地音乐」下拉刷新开始扫描',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _adding ? null : _addFolder,
                      icon: _adding
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.create_new_folder),
                      label: const Text('添加目录'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            // 底部留白计入悬浮底栏 + 播放栏（Shell 注入值已含系统安全区），
            // 防止列表尾部条目/删除按钮被遮挡。
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 24,
            ),
            itemCount: folders.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final f = folders[i];
              return ListTile(
                leading: Icon(Icons.folder, color: scheme.primary),
                title: Text(
                  f.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${f.songCount} 首'),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: () => _removeFolder(f.path),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 页面正中央的 FAB 位置：悬浮底栏/播放栏固定占据底部条带，默认
/// endFloat/centerFloat 都会被遮挡，居中悬浮最稳妥。
class _CenterFabLocation extends FloatingActionButtonLocation {
  const _CenterFabLocation();

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final size = scaffoldGeometry.floatingActionButtonSize;
    return Offset(
      (scaffoldGeometry.scaffoldSize.width - size.width) / 2,
      (scaffoldGeometry.scaffoldSize.height - size.height) / 2,
    );
  }
}
