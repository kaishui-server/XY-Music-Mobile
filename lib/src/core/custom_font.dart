import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'db_path.dart';

/// 自定义字体的固定 family 名。运行时经 FontLoader 注册；Flutter 引擎
/// 中同 family 后注册的字体优先生效，因此更换字体无需更换 family 名。
const kCustomFontFamily = 'xy_custom_font';

/// 字体文件统一保存路径（应用数据目录 appearance 下）。
Future<String> customFontFilePath() async {
  final appDir = await resolveAppDataDir();
  return p.join(appDir, 'appearance', 'custom_font.ttf');
}

/// 把字体文件注册为 [kCustomFontFamily]。文件不存在或解析失败
/// 返回 false（FontLoader 对损坏数据会抛异常，这里统一吞掉）。
Future<bool> loadCustomFont(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return false;
    final loader = FontLoader(kCustomFontFamily)
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length),
        ),
      );
    await loader.load();
    return true;
  } catch (_) {
    return false;
  }
}

/// 启动时恢复自定义字体：设置里启用了自定义字体且字体文件仍存在时
/// 注册，保证第一帧就渲染正确字体；任何失败都静默回退系统默认。
Future<void> restoreCustomFontAtStartup() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final family = (prefs.getString('fontFamily') ?? '').trim();
    if (family.isEmpty) return;
    await loadCustomFont(await customFontFilePath());
  } catch (_) {
    // 注册失败时使用系统默认字体，不阻断启动流程。
  }
}
