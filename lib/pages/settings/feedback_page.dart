import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;

import '../../src/auth/auth_provider.dart';
import '../../src/logging/app_log_store.dart';
import '../../src/navigation/animated_page_route.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/top_notice.dart';

class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage({super.key});

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

enum _FeedbackType { problem, suggestion }

class _FeedbackPageState extends ConsumerState<FeedbackPage> {
  final _contentController = TextEditingController();
  final _logs = AppLogStore.instance;
  _FeedbackType _type = _FeedbackType.problem;
  final _images = <String>[];
  bool _attachErrorLogs = false;
  bool _attachAllLogs = false;
  bool _compressingImage = false;
  bool _submitting = false;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  List<AppLogEntry> get _allLogs => _logs.query();
  List<AppLogEntry> get _errorLogs => _logs.query(errorsOnly: true);

  Future<String?> _compressImage(PlatformFile file) async {
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) return null;
    if (bytes.length > 8 * 1024 * 1024) {
      throw Exception('${file.name} 超过 8MB，已跳过');
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('${file.name} 无法读取');
    final source = img.bakeOrientation(decoded);
    final maxSide = source.width > source.height ? source.width : source.height;
    final resized = maxSide > 1600
        ? img.copyResize(
            source,
            width: source.width >= source.height
                ? 1600
                : (source.width * 1600 / source.height).round(),
            height: source.height >= source.width
                ? 1600
                : (source.height * 1600 / source.width).round(),
            interpolation: img.Interpolation.average,
          )
        : source;
    var quality = 82;
    var encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    while (encoded.length > 6 * 1024 * 1024 && quality > 35) {
      quality -= 10;
      encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    }
    final dataUrl = 'data:image/jpeg;base64,${base64Encode(encoded)}';
    if (dataUrl.length > 8 * 1024 * 1024) {
      throw Exception('${file.name} 压缩后仍然过大，已跳过');
    }
    return dataUrl;
  }

  Future<void> _pickImages() async {
    if (_compressingImage || _images.length >= 6) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
        // 禁用插件压缩：其原生实现写入公共 Pictures 目录，Android 10
        // 分区存储下无权限会直接崩溃。页面自身有压缩逻辑。
        compressionQuality: 0,
      );
      if (result == null || result.files.isEmpty) return;
      final files = result.files.take(6 - _images.length).toList();
      setState(() => _compressingImage = true);
      var skipped = 0;
      for (final file in files) {
        try {
          final dataUrl = await _compressImage(file);
          if (dataUrl == null) {
            skipped++;
          } else {
            _images.add(dataUrl);
          }
        } catch (_) {
          skipped++;
        }
      }
      if (!mounted) return;
      setState(() {});
      if (skipped > 0) {
        XyNotice.show(
          context,
          message: '$skipped 张图片未能添加',
          type: XyNoticeType.warning,
        );
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '选择图片失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _compressingImage = false);
    }
  }

  String _formatLogs(List<AppLogEntry> entries) {
    final buffer = StringBuffer()
      ..writeln('XY Music 日志')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('日志数量：${entries.length}')
      ..writeln(List.filled(72, '=').join());
    for (final entry in entries) {
      buffer
        ..writeln(
          '[${entry.time.toIso8601String()}] [${entry.level.name.toUpperCase()}]',
        )
        ..writeln(entry.message)
        ..writeln(List.filled(72, '-').join());
      if (buffer.length > 500000) break;
    }
    return buffer.toString();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final auth = ref.read(authProvider);
    if (!auth.isLoggedIn) {
      XyNotice.show(
        context,
        message: '请先登录账号后再提交反馈',
        type: XyNoticeType.warning,
      );
      return;
    }
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      XyNotice.show(context, message: '请填写反馈内容', type: XyNoticeType.error);
      return;
    }
    if (content.length > 1000) {
      XyNotice.show(
        context,
        message: '内容不能超过 1000 字',
        type: XyNoticeType.error,
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final errorLogs = _type == _FeedbackType.problem && _attachErrorLogs
          ? _formatLogs(_errorLogs)
          : null;
      final allLogs = _type == _FeedbackType.problem && _attachAllLogs
          ? _formatLogs(_allLogs)
          : null;
      await ref
          .read(authProvider.notifier)
          .submitFeedback(
            title: _type == _FeedbackType.suggestion ? '功能建议' : '问题反馈',
            content: content,
            feedbackType: _type == _FeedbackType.suggestion
                ? 'suggestion'
                : 'problem',
            errorLogs: errorLogs,
            allLogs: allLogs,
            images: _type == _FeedbackType.suggestion
                ? List.of(_images)
                : const [],
          );
      if (!mounted) return;
      _contentController.clear();
      setState(() {
        _images.clear();
        _attachErrorLogs = false;
        _attachAllLogs = false;
      });
      XyNotice.show(
        context,
        message: '反馈已提交，感谢您的支持',
        type: XyNoticeType.success,
      );
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '提交失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _showMyFeedback() async {
    if (!ref.read(authProvider).isLoggedIn) {
      XyNotice.show(
        context,
        message: '请先登录账号后再查看反馈',
        type: XyNoticeType.warning,
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _MyFeedbackSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final scheme = Theme.of(context).colorScheme;
    final canAttachLogs = _allLogs.isNotEmpty || _errorLogs.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('问题反馈')),
      body: XyPageBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
          children: [
            Text(
              '提交使用中遇到的问题或功能建议，我们会认真查看每一条反馈。',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 16),
            if (!auth.isLoggedIn)
              Card(
                color: scheme.tertiaryContainer.withValues(alpha: .45),
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('请先登录账号后再提交反馈'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/account?from=settings'),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '反馈类型',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    SegmentedButton<_FeedbackType>(
                      segments: const [
                        ButtonSegment(
                          value: _FeedbackType.problem,
                          label: Text('问题反馈'),
                          icon: Icon(Icons.bug_report_outlined),
                        ),
                        ButtonSegment(
                          value: _FeedbackType.suggestion,
                          label: Text('功能建议'),
                          icon: Icon(Icons.lightbulb_outline),
                        ),
                      ],
                      selected: {_type},
                      onSelectionChanged: auth.isLoggedIn
                          ? (value) => setState(() => _type = value.first)
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _contentController,
                      enabled: auth.isLoggedIn,
                      maxLength: 1000,
                      minLines: 6,
                      maxLines: 10,
                      decoration: InputDecoration(
                        labelText: '详细内容',
                        hintText: _type == _FeedbackType.suggestion
                            ? '请描述你希望新增或改进的功能'
                            : '请详细描述问题现象和复现步骤',
                        alignLabelWithHint: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_type == _FeedbackType.problem && canAttachLogs) ...[
                      const SizedBox(height: 2),
                      if (_errorLogs.isNotEmpty)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('附上错误日志'),
                          value: _attachErrorLogs,
                          onChanged: auth.isLoggedIn
                              ? (value) => setState(
                                  () => _attachErrorLogs = value ?? false,
                                )
                              : null,
                        ),
                      if (_allLogs.isNotEmpty)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('附上全部日志'),
                          value: _attachAllLogs,
                          onChanged: auth.isLoggedIn
                              ? (value) => setState(
                                  () => _attachAllLogs = value ?? false,
                                )
                              : null,
                        ),
                    ],
                    if (_type == _FeedbackType.suggestion) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(child: Text('反馈图片（可选，最多 6 张）')),
                          OutlinedButton.icon(
                            onPressed:
                                auth.isLoggedIn &&
                                    !_compressingImage &&
                                    _images.length < 6
                                ? _pickImages
                                : null,
                            icon: _compressingImage
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                            label: const Text('添加图片'),
                          ),
                        ],
                      ),
                      if (_images.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _images.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemBuilder: (context, index) => _imagePreview(index),
                        ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: auth.isLoggedIn && !_submitting
                                ? _submit
                                : null,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.send_rounded),
                            label: Text(_submitting ? '正在提交…' : '提交反馈'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: auth.isLoggedIn ? _showMyFeedback : null,
                          icon: const Icon(Icons.history_rounded),
                          label: const Text('我的反馈'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imagePreview(int index) {
    final data = _images[index];
    final comma = data.indexOf(',');
    final bytes = comma > 0
        ? base64Decode(data.substring(comma + 1))
        : Uint8List(0);
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(bytes, fit: BoxFit.cover),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _images.removeAt(index)),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ),
      ],
    );
  }
}

class _MyFeedbackSheet extends ConsumerStatefulWidget {
  const _MyFeedbackSheet();

  @override
  ConsumerState<_MyFeedbackSheet> createState() => _MyFeedbackSheetState();
}

class _MyFeedbackSheetState extends ConsumerState<_MyFeedbackSheet> {
  late Future<List<UserFeedbackItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(authProvider.notifier).listMyFeedback();
  }

  String _status(String value) => switch (value) {
    'pending' => '待处理',
    'processing' => '处理中',
    'resolved' => '已处理',
    'rejected' => '已拒绝',
    _ => value,
  };

  Future<void> _showImages(List<String> images) async {
    if (images.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: PageView.builder(
            itemCount: images.length,
            itemBuilder: (_, index) => InteractiveViewer(
              child: Image.network(images[index], fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '我的反馈',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<UserFeedbackItem>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('获取反馈失败：${snapshot.error}'));
                  }
                  final items = snapshot.data ?? const <UserFeedbackItem>[];
                  if (items.isEmpty) return const Center(child: Text('暂无反馈记录'));
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final images = [...item.images, ...item.resolveImages];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _openDetail(item),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      item.feedbackType == 'suggestion'
                                          ? '功能建议'
                                          : '问题反馈',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _status(item.status),
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.content,
                                  style: const TextStyle(height: 1.5),
                                ),
                                if (item.adminReply.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '管理员回复：${item.adminReply}',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                                if (item.resolveNote.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '处理说明（${item.assignee.isEmpty ? '管理员' : item.assignee}）：${item.resolveNote}',
                                    ),
                                  ),
                                ],
                                if (item.status == 'rejected' &&
                                    item.rejectReason.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.errorContainer,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '拒绝原因：${item.rejectReason}',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                ],
                                if (images.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 64,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: images.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(width: 8),
                                      itemBuilder: (_, imageIndex) =>
                                          GestureDetector(
                                            onTap: () => _showImages(images),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Image.network(
                                                images[imageIndex],
                                                width: 64,
                                                height: 64,
                                                fit: BoxFit.cover,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  item.createdAt,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDetail(UserFeedbackItem item) async {
    await Navigator.of(context).push(
      XyAnimatedPageRoute<void>(
        builder: (_) => _FeedbackDetailPage(item: item),
      ),
    );
  }
}

class _FeedbackDetailPage extends StatelessWidget {
  const _FeedbackDetailPage({required this.item});

  final UserFeedbackItem item;

  String _status(String value) => switch (value) {
    'pending' => '待处理',
    'processing' => '处理中',
    'resolved' => '已处理',
    'rejected' => '已拒绝',
    _ => value,
  };

  String _time(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value.isEmpty ? '—' : value;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _showImages(BuildContext context, List<String> images) async {
    if (images.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: PageView.builder(
            itemCount: images.length,
            itemBuilder: (_, index) => InteractiveViewer(
              child: Image.network(images[index], fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final images = [...item.images, ...item.resolveImages];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('反馈详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(
            children: [
              Text(
                item.feedbackType == 'suggestion' ? '功能建议' : '问题反馈',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Chip(label: Text(_status(item.status))),
            ],
          ),
          const SizedBox(height: 8),
          if (item.title.trim().isNotEmpty)
            Text(item.title, style: Theme.of(context).textTheme.titleMedium),
          if (item.title.trim().isNotEmpty) const SizedBox(height: 12),
          _section(
            context,
            '反馈内容',
            Text(
              item.content.isEmpty ? '无内容' : item.content,
              style: const TextStyle(height: 1.6),
            ),
          ),
          _section(
            context,
            '时间信息',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('提交时间：${_time(item.createdAt)}'),
                if (item.updatedAt.isNotEmpty &&
                    item.updatedAt != item.createdAt)
                  Text('更新时间：${_time(item.updatedAt)}'),
                if (item.repliedAt.isNotEmpty)
                  Text('回复时间：${_time(item.repliedAt)}'),
              ],
            ),
          ),
          if (images.isNotEmpty)
            _section(
              context,
              '上传内容',
              SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => GestureDetector(
                    onTap: () => _showImages(context, images),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Image.network(
                        images[index],
                        width: 76,
                        height: 76,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (item.hasErrorLogs || item.hasAllLogs)
            _section(
              context,
              '日志附件',
              Text(
                '${[if (item.hasErrorLogs) '错误日志', if (item.hasAllLogs) '完整日志'].join('、')}已随反馈上传',
              ),
            ),
          if (item.adminReply.isNotEmpty)
            _section(
              context,
              '管理员回复',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.adminReply, style: const TextStyle(height: 1.6)),
                  const SizedBox(height: 8),
                  Text(
                    '回复时间：${_time(item.repliedAt)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (item.resolveNote.isNotEmpty)
            _section(
              context,
              '处理说明',
              Text(item.resolveNote, style: const TextStyle(height: 1.6)),
            ),
          if (item.rejectReason.isNotEmpty)
            _section(
              context,
              '拒绝原因',
              Text(
                item.rejectReason,
                style: TextStyle(height: 1.6, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
