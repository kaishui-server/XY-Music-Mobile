import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../src/logging/app_log_store.dart';
import '../../src/widgets/top_notice.dart';

enum _LogTimeRange {
  minutes5('最近 5 分钟', Duration(minutes: 5)),
  minutes10('最近 10 分钟', Duration(minutes: 10)),
  minutes15('最近 15 分钟', Duration(minutes: 15)),
  minutes20('最近 20 分钟', Duration(minutes: 20)),
  hour1('最近 1 小时', Duration(hours: 1)),
  hours3('最近 3 小时', Duration(hours: 3)),
  all('全部', null);

  const _LogTimeRange(this.label, this.duration);

  final String label;
  final Duration? duration;
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _store = AppLogStore.instance;
  _LogTimeRange _range = _LogTimeRange.all;
  int _maxEntries = 500;
  bool _warningOnly = false;
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _store.initialize();
    if (!mounted) return;
    setState(() {
      _maxEntries = _store.maxEntries;
      _warningOnly = _store.warningOnly;
      _loading = false;
    });
  }

  List<AppLogEntry> _query({bool errorsOnly = false}) =>
      _store.query(since: _range.duration, errorsOnly: errorsOnly);

  Future<void> _setMaxEntries(int value) async {
    setState(() => _maxEntries = value);
    await _store.setMaxEntries(value);
  }

  Future<void> _setWarningOnly(bool value) async {
    setState(() => _warningOnly = value);
    await _store.setWarningOnly(value);
  }

  Future<void> _clearLogs() async {
    if (_store.entries.isEmpty) {
      XyNotice.show(context, message: '当前没有可清空的日志');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text('将删除本机保存的全部日志，删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.clear();
    if (!mounted) return;
    setState(() {});
    XyNotice.show(context, message: '日志已清空');
  }

  Future<void> _export({required bool errorsOnly}) async {
    if (_exporting) return;
    final entries = _query(errorsOnly: errorsOnly);
    if (entries.isEmpty) {
      XyNotice.show(context, message: '当前时间范围内没有可导出的日志');
      return;
    }
    setState(() => _exporting = true);
    try {
      final type = errorsOnly ? 'error' : 'all';
      final fileName =
          'xy_music_${type}_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: errorsOnly ? '导出错误日志' : '导出全部日志',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        bytes: Uint8List.fromList(utf8.encode(_format(entries))),
      );
      if (!mounted || path == null || path.isEmpty) return;
      XyNotice.show(context, message: '日志已导出（${entries.length} 条）');
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '导出日志失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _format(List<AppLogEntry> entries) {
    final buffer = StringBuffer()
      ..writeln('XY Music 日志')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('时间范围：${_range.label}')
      ..writeln('日志数量：${entries.length}')
      ..writeln(List.filled(72, '=').join());
    for (final entry in entries) {
      buffer
        ..writeln(
          '[${entry.time.toIso8601String()}] [${entry.level.name.toUpperCase()}]',
        )
        ..writeln(entry.message)
        ..writeln(List.filled(72, '-').join());
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final allCount = _query().length;
    final errorCount = _query(errorsOnly: true).length;
    return Scaffold(
      appBar: AppBar(title: const Text('日志')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _sectionTitle(context, '日志保存'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.format_list_numbered),
                        title: const Text('保存日志条数'),
                        subtitle: const Text('超出数量后优先删除最早的日志'),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _maxEntries,
                            items: const [100, 300, 500, 1000, 2000, 5000]
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text('$value 条'),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) _setMaxEntries(value);
                            },
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 56),
                      SwitchListTile(
                        secondary: const Icon(Icons.filter_alt_outlined),
                        title: const Text('只记录警告和报错日志'),
                        subtitle: const Text('开启后普通运行信息不会保存'),
                        value: _warningOnly,
                        onChanged: _setWarningOnly,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle(context, '日志管理'),
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.delete_sweep_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: const Text('一键清空日志'),
                    subtitle: const Text('删除本机保存的全部日志，操作不可恢复'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _clearLogs,
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle(context, '导出范围'),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: const Text('日志时间范围'),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<_LogTimeRange>(
                        value: _range,
                        items: _LogTimeRange.values
                            .map(
                              (range) => DropdownMenuItem(
                                value: range,
                                child: Text(range.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) setState(() => _range = value);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle(context, '导出日志'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text('导出全部日志（$allCount 条）'),
                        subtitle: const Text('包含普通信息、警告和错误'),
                        trailing: const Icon(Icons.file_download_outlined),
                        onTap: _exporting
                            ? null
                            : () => _export(errorsOnly: false),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        title: Text('导出错误日志（$errorCount 条）'),
                        subtitle: const Text('仅导出错误级别日志'),
                        trailing: const Icon(Icons.file_download_outlined),
                        onTap: _exporting
                            ? null
                            : () => _export(errorsOnly: true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '日志只保存在本机，导出后可提供给开发者定位问题。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
