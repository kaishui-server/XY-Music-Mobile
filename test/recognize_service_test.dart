import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/recognize/recognize_service.dart';

void main() {
  test('电脑版酷狗识曲响应可映射为移动端可播放歌曲', () {
    final payload = jsonEncode({
      'status': 200,
      'body': jsonEncode({
        'status': 1,
        'data': [
          {
            'songname': '测试识曲',
            'singername': '测试歌手',
            'album': [
              {
                'albumname': '测试专辑',
                'albumid': 'album-1',
                'sizable_cover': '//c1.kgimg.com/{size}/cover.jpg',
              },
            ],
            'album_audio_id': 12345,
            'hash': 'HASH128',
            'hash_320': 'HASH320',
            'timelength': 185000,
            'dist': 0.08,
          },
        ],
      }),
    });

    final matches = parseRecognizePayload(payload);

    expect(matches, hasLength(1));
    expect(matches.single.confidence, closeTo(.92, .001));
    expect(matches.single.song.path, 'lx://kg/HASH128');
    expect(matches.single.song.title, '测试识曲');
    expect(matches.single.song.duration, 185);
    expect(
      matches.single.song.coverUrl,
      'https://imge.kugou.com/400/cover.jpg',
    );
    expect(
      (matches.single.song.pluginData?['lx'] as Map)['_types']['320k']['hash'],
      'HASH320',
    );
  });

  test('识曲服务状态非成功时返回空结果', () {
    final payload = jsonEncode({
      'status': 200,
      'body': jsonEncode({'status': 0, 'data': null}),
    });

    expect(parseRecognizePayload(payload), isEmpty);
  });

  test('48kHz PCM 会按电脑版算法降采样为 8kHz PCM', () {
    final source = <int>[];
    for (var i = 0; i < 48000; i++) {
      const sample = 1200;
      source
        ..add(sample & 0xff)
        ..add((sample >> 8) & 0xff);
    }

    final output = prepareRecognitionPcm(microphone: source);

    expect(output, hasLength(8000 * 2));
    expect(pcm16Peak(output), 1200);
  });

  test('系统声与麦克风声可混合且不会溢出 PCM16', () {
    const positive = [0xff, 0x7f, 0xff, 0x7f];
    const negative = [0x00, 0x80, 0x00, 0x80];

    final mixed = mixPcm16Mono(positive, negative);

    expect(mixed, hasLength(4));
    expect(pcm16Peak(mixed), lessThanOrEqualTo(1));
  });
}
