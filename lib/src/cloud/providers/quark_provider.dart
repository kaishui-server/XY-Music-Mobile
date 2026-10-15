// 夸克网盘：继承 QuarkUcBase，仅声明品牌常量与免速直链兜底路由。

import '../cloud_types.dart';
import '../cloud_http.dart';
import 'quark_uc_base.dart';

class QuarkProvider extends QuarkUcBase {
  const QuarkProvider();

  @override
  String get id => 'quark';

  @override
  String get displayName => '夸克网盘';

  @override
  String get apiHost => 'drive-pc.quark.cn';

  @override
  String get webHost => 'pan.quark.cn';

  @override
  String get pr => 'ucpro';

  @override
  String get uaBrand => 'quark-cloud-drive';

  // passport.quark.cn 域名已不可解析（ERR_NAME_NOT_RESOLVED），登录
  // 改为 pan.quark.cn 同域登录入口（实测可达）。
  @override
  String get webviewLoginUrl => 'https://pan.quark.cn/login';

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        // 网页版登录态分散在 __pus/__puus/_UP_A4A_11_/__kp/__kps 等
        // Cookie（kps/sign 是移动端 URL 参数，网页端未必种 cookie），
        // 任一命中即视为会话凭据齐备，再由 completeLogin 二次校验。
        cookieNamesAny: [
          '__pus',
          '__puus',
          '_UP_A4A_11_',
          '__kp',
          '__kps',
          'kps',
          'sign',
        ],
        cookieDomains: ['pan.quark.cn'],
        pollIntervalMs: 500,
      );

  /// 免速兜底路由：fast-transfer sendToPC 通道（按竞品抓包推测；
  /// route1 失败后 best-effort，任何异常吞掉归一为直链失败）。
  @override
  Future<CloudDirectLink> directLinkRoute2(
      Map<String, String> cred, CloudFile file) async {
    try {
      final tokResp = await cloudPostJson(
        'https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/'
        'acquire_dl_token?pr=ucpro&fr=pc',
        body: {'file_id': file.id},
        headers: authHeaders(cred),
      );
      final dlToken = ((tokResp.json['data'] as Map<String, dynamic>?)
                  ?['dl_token'] ??
              '')
          .toString();
      if (dlToken.isEmpty) throw const CloudException('直链获取失败');
      final resp = await cloudPostJson(
        'https://$apiHost/1/clouddrive/file/download?$commonQuery'
        '&dl_token=${Uri.encodeQueryComponent(dlToken)}',
        body: {
          'fids': [file.id],
        },
        headers: authHeaders(cred),
      );
      final data = resp.json['data'];
      String? url;
      if (data is List && data.isNotEmpty) {
        url =
            (data.first as Map<String, dynamic>?)?['download_url']?.toString();
      } else if (data is Map<String, dynamic>) {
        url = data['download_url']?.toString();
      }
      if (url == null || url.isEmpty) throw const CloudException('直链获取失败');
      return CloudDirectLink(
        url: url,
        headers: {'User-Agent': desktopUa, 'Referer': 'https://$webHost/'},
        fileName: file.name,
        size: file.size,
        expireAt: DateTime.now().add(const Duration(hours: 2)),
      );
    } on CloudException {
      rethrow;
    } catch (_) {
      throw const CloudException('直链获取失败');
    }
  }
}
