import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'performance_probe.dart';

/// 探针报告弹窗：App 内自展示（不依赖 adb）。仅当
/// [kPerformanceProbeEntryVisible] 为 true 时入口可见。
class ProbeReportDialog extends StatefulWidget {
  const ProbeReportDialog({super.key});

  @override
  State<ProbeReportDialog> createState() => _ProbeReportDialogState();
}

class _ProbeReportDialogState extends State<ProbeReportDialog> {
  String _report = '';
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _report = PerformanceProbe.instance.buildReport();
  }

  Future<void> _refresh() async {
    setState(() {
      _report = PerformanceProbe.instance.buildReport();
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('报告已复制到剪贴板')));
  }

  Future<void> _dump() async {
    if (_writing) return;
    setState(() => _writing = true);
    String path;
    try {
      path = await PerformanceProbe.instance.dumpReportToFile();
    } catch (e) {
      if (!mounted) return;
      setState(() => _writing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('写入失败: $e')));
      return;
    }
    if (!mounted) return;
    setState(() => _writing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已写入: $path')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('性能探针报告'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  _report,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '采集: 久播 10 分钟 + 切换动画后查看；本弹窗仅 debug 构建显示。',
              style: TextStyle(fontSize: 11, color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _refresh, child: const Text('刷新')),
        TextButton(onPressed: _copy, child: const Text('复制')),
        TextButton(
          onPressed: _dump,
          child: Text(_writing ? '写入中…' : '写入文档目录'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 从播放详情页更多菜单拉起报告弹窗：先收起弹层（用 root navigator
/// context 保证弹窗挂在常驻 navigator 上），再展示报告。
Future<void> showPerformanceProbeReport(BuildContext context) {
  final navigator = Navigator.of(context, rootNavigator: true);
  Navigator.pop(context);
  return showDialog<void>(
    context: navigator.context,
    builder: (_) => const ProbeReportDialog(),
  );
}
