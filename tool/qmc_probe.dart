// QQ L1 全档位解密播放测试（真实 Source API + 真实加密流）：
// ① encrypted=1 拿 ekey + mflac 直链；② decryptEKey → QmcDecoder；
// ③ 首段 Range 解密 → 验证 fLaC/ID3/OggS 魔数（模拟起播）；
// ④ 中段 Range 解密 → 验证 seek 场景全局 offset 定位（模拟拖动进度条）。
// 运行：dart run tool/qmc_probe.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xy_music/src/player/qmc_crypto.dart';

const kSourceApiUrl = 'https://qm.xww.ccwu.cc/api/source/song';
const kSourceApiKey =
    '3ccntJ6g64iGRo5_Qsvp6JxTpkPuErQDfmXu7LttMjDcKHycAfbrJrst-nCGzu2ClPKN-SjZG050IpEKmdMgmw';
// A Little Love - 冯曦妤（QQ songmid）
const kSongMid = '001IAqkK0p2b7s';

void log(String s) => stdout.writeln('[qmc-probe] $s');

String _magicName(Uint8List b) {
  if (b.length >= 4 &&
      b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
    return 'fLaC';
  }
  if (b.length >= 3 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
    return 'ID3';
  }
  if (b.length >= 4 &&
      b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
    return 'OggS';
  }
  if (b.length >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) {
    return 'MP3帧';
  }
  return '未知';
}

Future<void> main() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  var pass = 0, fail = 0;
  // Source API 的 quality ID（对齐 MusicFree 插件 qualityToSourceApi 映射：
  // 128k→mp3128、320k→mp3320、atmos→galaxy、atmos_plus→galaxy51）。
  for (final entry in <String, String>{
    '128k': 'mp3128',
    '320k': 'mp3320',
    'flac': 'flac',
    'hires': 'hires',
    'vinyl': 'vinyl',
    'dolby': 'dolby',
    'atmos': 'galaxy',
    'atmos_plus': 'galaxy51',
    'master': 'master',
  }.entries) {
    final quality = entry.key;
    try {
      // ① Source API（插件同款 encrypted=1）
      final req = await client.getUrl(
        Uri.parse(
            '$kSourceApiUrl?id=$kSongMid&quality=${entry.value}&encrypted=1'),
      );
      req.headers.set('X-API-KEY', kSourceApiKey);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>?;
      final ekey = data?['ekey'] as String?;
      final url = data?['url'] as String?;
      if (url == null || url.isEmpty) {
        log('[$quality] 无直链（code=${json['code']} data键='
            '${data?.keys.join(',') ?? '无'}）——跳过');
        fail++;
        continue;
      }
      if (ekey == null || ekey.isEmpty) {
        // 低品质可能返回明文直链（无 ekey），直接验证魔数。
        final plain = await _fetchAndDecrypt(client, url, null, 0, 8192);
        final magic = _magicName(plain);
        log('[$quality] 明文直链（无ekey）头: '
            '${plain.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} → $magic');
        if (magic == '未知') {
          fail++;
        } else {
          pass++;
        }
        continue;
      }

      // ② ekey 解密
      final rawKey = decryptEKey(ekey);
      log('[$quality] rawKeyLen=${rawKey.length}');

      // ③ 起播：首段 Range 0-8191 解密
      final head = await _fetchAndDecrypt(client, url, rawKey, 0, 8192);
      final headMagic = _magicName(head);
      log('[$quality] 起播解密头 8 字节: '
          '${head.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} '
          '→ $headMagic');
      if (headMagic == '未知') {
        log('[$quality] ✗ 起播魔数无法识别');
        fail++;
        continue;
      }

      // ④ seek：中段 Range 解密（对齐 ExoPlayer Range bytes=N- 行为）
      //    先探测总大小（Content-Range total）再取中段。
      final probe = await client.openUrl('GET', Uri.parse(url));
      probe.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final probeResp = await probe.close();
      final cr = probeResp.headers.value(HttpHeaders.contentRangeHeader);
      await probeResp.drain<void>();
      final total = int.tryParse(cr?.split('/')[1] ?? '') ?? 0;
      if (total > 0x40000) {
        final mid = total ~/ 2;
        final midBuf =
            await _fetchAndDecrypt(client, url, rawKey, mid, 4096);
        final nonZero = midBuf.any((b) => b != 0);
        log('[$quality] seek 解密 offset=$mid/$total '
            '非全零=$nonZero');
        if (!nonZero) {
          log('[$quality] ✗ seek 段解密结果全零（offset 定位异常）');
          fail++;
          continue;
        }
      }
      log('[$quality] ✓ 通过');
      pass++;
    } catch (e) {
      log('[$quality] ✗ 异常: $e');
      fail++;
    }
  }
  log('结果：通过=$pass 失败=$fail');
  exit(fail > 0 ? 1 : 0);
}

Future<Uint8List> _fetchAndDecrypt(
  HttpClient client,
  String url,
  Uint8List? rawKey,
  int start,
  int length,
) async {
  final dl = await client.openUrl('GET', Uri.parse(url));
  dl.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${start + length - 1}');
  final dlResp = await dl.close();
  final enc = <int>[];
  await for (final chunk in dlResp) {
    enc.addAll(chunk);
    if (enc.length >= length) break;
  }
  final buf = Uint8List.fromList(enc.take(length).toList());
  if (rawKey == null) return buf; // 明文直链不解密
  final decoder = QmcDecoder.fromRawKey(rawKey);
  decoder.decryptChunk(buf, start);
  return buf;
}
