import 'dart:io';

/// 下载音质校验结果。
class DownloadQualityVerification {
  const DownloadQualityVerification({
    required this.path,
    required this.quality,
    this.warning,
  });

  /// 最终文件路径（扩展名被纠正时与下载路径不同）。
  final String path;

  /// 实际音质标识（flac / 320k / 128k 等，检测失败时回退为所选音质）。
  final String quality;

  /// 实际音质低于所选音质时的警告文案，无降级时为 null。
  final String? warning;
}

const Set<String> _losslessQualityTokens = {
  'flac',
  'flac24bit',
  'hires',
  'hi-res',
  'master',
  'vinyl',
  'ape',
  'wav',
  'sq',
  'lossless',
};

bool _isLosslessQuality(String quality) =>
    _losslessQualityTokens.contains(quality.trim().toLowerCase());

bool _isLosslessFormat(String? format) =>
    format == 'flac' || format == 'wav';

/// 读取文件头 magic bytes 判断真实音频格式。
/// 返回 flac / mp3 / ogg / m4a / wav，无法识别时返回 null。
Future<String?> detectAudioFormatByHeader(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  RandomAccessFile? raf;
  try {
    raf = await file.open(mode: FileMode.read);
    final bytes = await raf.read(12);
    if (bytes.length < 12) return null;
    // fLaC
    if (bytes[0] == 0x66 &&
        bytes[1] == 0x4C &&
        bytes[2] == 0x61 &&
        bytes[3] == 0x43) {
      return 'flac';
    }
    // ID3
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return 'mp3';
    }
    // MPEG audio sync bits
    if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
      return 'mp3';
    }
    // OggS
    if (bytes[0] == 0x4F &&
        bytes[1] == 0x67 &&
        bytes[2] == 0x67 &&
        bytes[3] == 0x53) {
      return 'ogg';
    }
    // ....ftyp
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return 'm4a';
    }
    // RIFF....WAVE
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45) {
      return 'wav';
    }
    return null;
  } finally {
    await raf?.close();
  }
}

String? _extForFormat(String format) => switch (format) {
  'flac' => '.flac',
  'mp3' => '.mp3',
  'ogg' => '.ogg',
  'm4a' => '.m4a',
  'wav' => '.wav',
  _ => null,
};

/// 按文件大小和时长估算实际码率（kbps），时长未知时返回 null。
Future<int?> _estimateBitrateKbps(String path, int durationSec) async {
  if (durationSec <= 0) return null;
  final size = await File(path).length();
  if (size <= 0) return null;
  return (size * 8 / durationSec / 1000).round();
}

/// 将估算码率归到常见档位，误差 15% 以内认为匹配。
String _normalizeLossyQuality(int kbps) {
  for (final tier in const [128, 192, 320]) {
    if ((kbps - tier).abs() <= tier * 0.15) return '${tier}k';
  }
  return '${kbps}k';
}

/// 下载完成后校验实际音质：
/// 1. magic bytes 检测真实格式，扩展名不符时重命名纠正；
/// 2. 按大小/时长估算实际码率，回写真实音质标识；
/// 3. 实际音质低于所选（如选无损拿到 MP3）时生成警告文案。
Future<DownloadQualityVerification> verifyDownloadedAudioQuality({
  required String savedPath,
  required String selectedQuality,
  required int durationSec,
  required String songTitle,
}) async {
  final format = await detectAudioFormatByHeader(savedPath);
  if (format == null) {
    return DownloadQualityVerification(
      path: savedPath,
      quality: selectedQuality,
    );
  }

  // 扩展名纠正：所选无损但实际是有损流时，按真实格式重命名文件。
  var finalPath = savedPath;
  final correctExt = _extForFormat(format);
  final currentExt = savedPath.toLowerCase().endsWith('.flac')
      ? '.flac'
      : savedPath.toLowerCase().endsWith('.mp3')
      ? '.mp3'
      : savedPath.toLowerCase().endsWith('.ogg')
      ? '.ogg'
      : savedPath.toLowerCase().endsWith('.m4a')
      ? '.m4a'
      : savedPath.toLowerCase().endsWith('.wav')
      ? '.wav'
      : '';
  if (correctExt != null && currentExt.isNotEmpty && currentExt != correctExt) {
    final renamed = savedPath.substring(
      0,
      savedPath.length - currentExt.length,
    ) + correctExt;
    try {
      final target = File(renamed);
      if (await target.exists()) await target.delete();
      await File(savedPath).rename(renamed);
      finalPath = renamed;
    } catch (_) {
      // 重命名失败时保留原文件名，仅影响展示，不影响内容。
    }
  }

  // 实际音质标识。
  String actualQuality;
  if (_isLosslessFormat(format)) {
    actualQuality = 'flac';
  } else {
    final kbps = await _estimateBitrateKbps(finalPath, durationSec);
    actualQuality = kbps == null ? format : _normalizeLossyQuality(kbps);
  }

  // 降级判断。
  String? warning;
  final selected = selectedQuality.trim().toLowerCase();
  if (_isLosslessQuality(selected) && !_isLosslessFormat(format)) {
    final label = '${format.toUpperCase()} $actualQuality';
    warning = '《$songTitle》所选${_qualityDisplayName(selected)}不可用，'
        '实际已下载 $label';
  } else if (selected == '320k' && !_isLosslessFormat(format)) {
    final kbps = await _estimateBitrateKbps(finalPath, durationSec);
    if (kbps != null && kbps < 250) {
      warning = '《$songTitle》所选 320k 不可用，实际已下载 $actualQuality';
    }
  }

  return DownloadQualityVerification(
    path: finalPath,
    quality: actualQuality,
    warning: warning,
  );
}

String _qualityDisplayName(String quality) => switch (quality) {
  'flac' => '无损 FLAC',
  'flac24bit' => '无损 FLAC 24bit',
  'hires' || 'hi-res' => 'Hi-Res',
  'master' => '母带',
  'vinyl' => '黑胶',
  _ => quality,
};
