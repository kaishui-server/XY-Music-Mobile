// 《一生一世》影视原声带封面不显示的回归测试。
// 根因：网易云 CDN picUrl 指向原始尺寸图片，该专辑封面原图 7.3MB，
// 超过 Rust 图片代理 5MB 上限被直接拒绝；系统媒体会话加载也会失败。
// 修复：normalizeCoverImageUrl 统一为 126.net 封面追加 ?param=800y800。
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/widgets/cover_image.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  group('normalizeCoverImageUrl 网易云封面缩放', () {
    test('126.net 封面 URL 追加 param=800y800', () {
      const url =
          'https://p1.music.126.net/ttavCZZSzkgfM6E_ZizEkw==/109951166394487469.jpg';
      final result = normalizeCoverImageUrl(url);
      expect(result, contains('param=800y800'));
      expect(result, startsWith('https://p1.music.126.net/'));
    });

    test('已带 param 的 URL 不重复追加', () {
      const url =
          'https://p2.music.126.net/vmCcDvD1H04e9gm97xsCqg==/109951163350929740.jpg?param=300y300';
      expect(normalizeCoverImageUrl(url), url);
    });

    test('其他 CDN 域名不受影响', () {
      const url = 'https://imgcache.qq.com/cover/123.jpg';
      expect(normalizeCoverImageUrl(url), url);
      const kugou = 'http://imge.kugou.com/stdmusic/240/abc.jpg';
      // 仅协议升级为 HTTPS，域名保持不变。
      expect(normalizeCoverImageUrl(kugou), 'https://imge.kugou.com/stdmusic/240/abc.jpg');
    });

    test('http 协议升级与 param 追加共存', () {
      const url = 'http://p3.music.126.net/abc==/def.jpg';
      final result = normalizeCoverImageUrl(url);
      expect(result, startsWith('https://p3.music.126.net/'));
      expect(result, contains('param=800y800'));
    });

    test('空地址保持为空', () {
      expect(normalizeCoverImageUrl(null), '');
      expect(normalizeCoverImageUrl(''), '');
    });
  });

  group('picId 兜底生成的封面地址自带缩放参数', () {
    // _neteasePicIdToUrl 是私有方法，通过 _extractCover 的 picId 兜底
    // 路径间接验证：构建 rawData 只含 picId_str 的节点。
    test('搜索结果仅 picId_str 时生成的 URL 含 param', () {
      final result = PluginRuntimeService.extractCoverForTest({
        'picId_str': '109951166394487469',
      });
      expect(result, isNotEmpty);
      expect(result, contains('p1.music.126.net'));
      expect(result, contains('param=800y800'));
    });
  });
}
