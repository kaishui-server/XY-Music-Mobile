import 'dart:async';
import 'dart:convert';

import '../library/library_provider.dart';
import '../rust/api.dart';

const recognizeMaxSeconds = 10;
const recognizeCancelledMessage = '识别已取消';
const recognizeCaptureSampleRate = 48000;
const recognizeTargetSampleRate = 8000;
const recognizeRequestTimeout = Duration(seconds: 20);

class RecognizeMatch {
  const RecognizeMatch({
    required this.song,
    required this.confidence,
    required this.raw,
  });

  final Song song;
  final double confidence;
  final Map<String, dynamic> raw;
}

Future<List<RecognizeMatch>> recognizePcm(List<int> pcm) async {
  try {
    final payload = await recognizeWithPcm(
      pcm: pcm,
    ).timeout(recognizeRequestTimeout);
    return parseRecognizePayload(payload);
  } on TimeoutException {
    await cancelRecognizeSystemAudio();
    throw TimeoutException('识别超时，请检查网络后重试');
  }
}

List<int> prepareRecognitionPcm({
  List<int> microphone = const [],
  List<int> systemAudio = const [],
  int sourceSampleRate = recognizeCaptureSampleRate,
}) {
  final microphone8k = microphone.isEmpty
      ? const <int>[]
      : resamplePcm16Mono(
          microphone,
          sourceSampleRate: sourceSampleRate,
          targetSampleRate: recognizeTargetSampleRate,
        );
  final system8k = systemAudio.isEmpty
      ? const <int>[]
      : resamplePcm16Mono(
          systemAudio,
          sourceSampleRate: sourceSampleRate,
          targetSampleRate: recognizeTargetSampleRate,
        );
  if (microphone8k.isEmpty) return system8k;
  if (system8k.isEmpty) return microphone8k;
  return mixPcm16Mono(microphone8k, system8k);
}

List<int> resamplePcm16Mono(
  List<int> input, {
  required int sourceSampleRate,
  required int targetSampleRate,
}) {
  final pcm = _stripWaveHeader(input);
  final sampleCount = pcm.length ~/ 2;
  if (sampleCount == 0 || sourceSampleRate <= 0 || targetSampleRate <= 0) {
    return const [];
  }
  if (sourceSampleRate == targetSampleRate) {
    return List<int>.from(pcm.take(sampleCount * 2));
  }
  final ratio = sourceSampleRate / targetSampleRate;
  final outputSamples = (sampleCount / ratio).floor();
  final output = List<int>.filled(outputSamples * 2, 0);
  for (var i = 0; i < outputSamples; i++) {
    final sourcePosition = i * ratio;
    final sourceIndex = sourcePosition.floor();
    final fraction = sourcePosition - sourceIndex;
    final first = _readPcm16(pcm, sourceIndex);
    final second = sourceIndex + 1 < sampleCount
        ? _readPcm16(pcm, sourceIndex + 1)
        : first;
    final value = (first * (1 - fraction) + second * fraction).round().clamp(
      -32768,
      32767,
    );
    output[i * 2] = value & 0xff;
    output[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return output;
}

List<int> mixPcm16Mono(List<int> first, List<int> second) {
  final sampleCount =
      (first.length > second.length ? first.length : second.length) ~/ 2;
  final output = List<int>.filled(sampleCount * 2, 0);
  for (var i = 0; i < sampleCount; i++) {
    final a = i * 2 + 1 < first.length ? _readPcm16(first, i) : 0;
    final b = i * 2 + 1 < second.length ? _readPcm16(second, i) : 0;
    final value = ((a + b) ~/ 2).clamp(-32768, 32767);
    output[i * 2] = value & 0xff;
    output[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return output;
}

int pcm16Peak(List<int> pcm) {
  var peak = 0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final value = _readPcm16(pcm, i ~/ 2).abs();
    if (value > peak) peak = value;
  }
  return peak;
}

int _readPcm16(List<int> bytes, int sampleIndex) {
  final offset = sampleIndex * 2;
  final raw = (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);
  return raw >= 0x8000 ? raw - 0x10000 : raw;
}

List<int> _stripWaveHeader(List<int> input) {
  if (input.length < 44 ||
      input[0] != 0x52 ||
      input[1] != 0x49 ||
      input[2] != 0x46 ||
      input[3] != 0x46) {
    return input;
  }
  for (var offset = 12; offset + 8 <= input.length;) {
    final isData =
        input[offset] == 0x64 &&
        input[offset + 1] == 0x61 &&
        input[offset + 2] == 0x74 &&
        input[offset + 3] == 0x61;
    final length =
        input[offset + 4] |
        (input[offset + 5] << 8) |
        (input[offset + 6] << 16) |
        (input[offset + 7] << 24);
    if (isData) {
      final start = offset + 8;
      return input.sublist(start, (start + length).clamp(start, input.length));
    }
    offset += 8 + length + (length.isOdd ? 1 : 0);
  }
  return input.sublist(44);
}

List<RecognizeMatch> parseRecognizePayload(String payload) {
  final envelope = jsonDecode(payload);
  if (envelope is! Map) throw const FormatException('识别响应格式错误');
  final response = Map<String, dynamic>.from(envelope);
  final status = (response['status'] as num?)?.toInt() ?? 0;
  if (status != 200) throw FormatException('识别请求失败 (HTTP $status)');

  final body = jsonDecode(response['body']?.toString() ?? '{}');
  if (body is! Map) throw const FormatException('识别结果格式错误');
  final bodyMap = Map<String, dynamic>.from(body);
  if ((bodyMap['status'] as num?)?.toInt() != 1) return const [];
  var data = bodyMap['data'];
  if (data is Map) {
    data = data['data'] ?? data['lists'] ?? data['result'];
  }
  if (data is! List) return const [];

  final matches = <RecognizeMatch>[];
  for (final value in data) {
    if (value is! Map) continue;
    final raw = Map<String, dynamic>.from(value);
    final match = _mapRecognizeMatch(raw);
    if (match != null) matches.add(match);
  }
  matches.sort((a, b) => b.confidence.compareTo(a.confidence));
  return matches;
}

RecognizeMatch? _mapRecognizeMatch(Map<String, dynamic> raw) {
  final title = _pickString([
    raw['songname'],
    raw['filename'],
    raw['name'],
  ], fallback: '未知歌曲');
  final artist = _pickString([
    raw['singername'],
    raw['author_name'],
    raw['singer'],
  ], fallback: '未知歌手');
  final albumRecord = _firstMap(raw['album']);
  final album = _pickString([
    albumRecord['albumname'],
    raw['album_name'],
    raw['albumname'],
  ], fallback: '未知专辑');
  final albumId = _pickString([
    albumRecord['albumid'],
    albumRecord['album_id'],
    raw['album_id'],
    raw['albumid'],
  ]);
  final coverUrl = _formatCoverUrl([
    raw['union_cover'],
    albumRecord['sizable_cover'],
    raw['album_sizable_cover'],
    raw['cover'],
  ]);
  final hash = _pickString([
    raw['hash'],
    raw['hash_128'],
    raw['FileHash'],
    raw['hash_320'],
    raw['hash_flac'],
  ]);
  final songmid = _pickString([
    raw['album_audio_id'],
    raw['mixsongid'],
    raw['audio_id'],
    raw['songid'],
    raw['song_id'],
    hash,
  ]);
  final playableId = hash.isNotEmpty ? hash : songmid;
  if (playableId.isEmpty) return null;

  final durationValue = _pickInt([
    raw['timelength'],
    raw['timelength_128'],
    raw['timelength_320'],
    raw['duration'],
  ]);
  final duration = durationValue > 1000 ? durationValue ~/ 1000 : durationValue;
  final types = <String, dynamic>{};
  if (hash.isNotEmpty) {
    types['128k'] = {'size': '', 'hash': hash};
  }
  final hash320 = _pickString([raw['hash_320']]);
  if (hash320.isNotEmpty) {
    types['320k'] = {'size': '', 'hash': hash320};
  }
  final hashFlac = _pickString([raw['hash_flac'], raw['hash_high']]);
  if (hashFlac.isNotEmpty) {
    types['flac'] = {'size': '', 'hash': hashFlac};
  }
  final lxSongInfo = <String, dynamic>{
    'songmid': songmid.isEmpty ? playableId : songmid,
    'source': 'kg',
    'hash': hash.isEmpty ? playableId : hash,
    'name': title,
    'singer': artist,
    'albumName': album,
    'albumId': albumId.isEmpty ? songmid : albumId,
    '_types': types,
  };
  final dist = double.tryParse(raw['dist']?.toString() ?? '0') ?? 1;
  final confidence = (1 - dist.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  final song = Song(
    path: 'lx://kg/$playableId',
    title: title,
    artist: artist,
    album: album,
    albumKey: '$album-$artist',
    duration: duration,
    format: '网络',
    coverUrl: coverUrl.isEmpty ? null : coverUrl,
    pluginData: {'lx': lxSongInfo},
  );
  return RecognizeMatch(song: song, confidence: confidence, raw: raw);
}

Map<String, dynamic> _firstMap(dynamic value) {
  if (value is List && value.isNotEmpty && value.first is Map) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return const {};
}

String _pickString(Iterable<dynamic> values, {String fallback = ''}) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return fallback;
}

int _pickInt(Iterable<dynamic> values) {
  for (final value in values) {
    final parsed = num.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed.toInt();
  }
  return 0;
}

String _formatCoverUrl(Iterable<dynamic> values) {
  var url = _pickString(values);
  if (url.isEmpty) return '';
  url = url.replaceAll('{size}', '400');
  if (url.startsWith('//')) url = 'https:$url';
  url = url.replaceFirst('http://', 'https://');
  return url.replaceFirst('c1.kgimg.com', 'imge.kugou.com');
}
