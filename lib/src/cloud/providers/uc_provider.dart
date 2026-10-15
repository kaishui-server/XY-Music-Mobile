// UC 网盘：继承 QuarkUcBase，仅声明品牌常量（接口与夸克同构）。

import '../cloud_types.dart';
import 'quark_uc_base.dart';

class UcProvider extends QuarkUcBase {
  const UcProvider();

  @override
  String get id => 'uc';

  @override
  String get displayName => 'UC网盘';

  // UC 的 API 网关已从 drive-pc.uc.cn 迁到 pc-api.uc.cn：前者 DNS 已无法
  // 解析（实测 Could not resolve host: drive-pc.uc.cn），所有业务请求直接
  // 失败，completeLogin 的会话二次校验恒不通过，绑定永远失败。
  // pc-api.uc.cn 在未登录时返回 401 code 31001「require login [guest]」，
  // 说明路由存在且可用。
  @override
  String get apiHost => 'pc-api.uc.cn';

  @override
  String get webHost => 'drive.uc.cn';

  // UC 云盘生产配置的 pr 参数是 UCBrowser（取自 UC 官网登录静态页前端
  // 的 `cloudDriveConfig:{cloudDriveHost:"https://pc-api.uc.cn",
  // paramInfo:{pr:"UCBrowser",fr:"pc"}}`）。此前填 ucpro 是把夸克的取值
  // 误套到 UC 上，服务端按客户端品牌识别，member 校验恒返回未登录。
  @override
  String get pr => 'UCBrowser';

  @override
  String get uaBrand => 'uc-cloud-drive';

  // pc.uc.cn 根路径已重定向到 www.uc.cn 浏览器门户页（无网盘登录表单），
  // 登录改为 drive.uc.cn 官方网盘登录页（实测含 微信扫码/UC扫码/短信验证/密码登录
  // 四种方式，与夸克 pan.quark.cn/login 同构）。
  @override
  String get webviewLoginUrl => 'https://drive.uc.cn/';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 同夸克：网页登录态 Cookie 候选任一命中即齐备，再二次校验。
        cookieNamesAny: [
          '__pus',
          '__puus',
          '_UP_A4A_11_',
          '__kp',
          '__kps',
          'kps',
          'sign',
        ],
        cookieDomains: ['drive.uc.cn'],
        // 仅主页域触发完成，避免登录页中途采集；登录前首页若已种
        // kps/sign，由 completeLogin 的 member 校验拦截。
        doneUrlPattern: RegExp(r'drive\.uc\.cn'),
        // UC 网页端登录卡片随固定宽度布局右移，注入缩放使登录入口
        // 完整落入视口（页面加载完成后每次注入，best-effort）。
        injectJs: 'document.body.style.zoom="0.82";',
        pollIntervalMs: 500,
      );
}

