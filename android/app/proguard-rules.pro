# XY Music R8 keep 规则（配合 minifyEnabled 收缩 Java/Kotlin 层体积）
# QQ OpenSDK（com.tencent.**）由 third_party/tencent_kit 的
# consumer-vendor-rules.pro 自动 keep，无需在此重复。

# Flutter 嵌入层与插件注册表：MethodChannel 编解码器经反射构造
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 应用自身的原生桥（MainActivity / StoragePermissionBridge / QQ 分享回调）
-keep class com.xymusic.mobile.** { *; }

# QQ OpenSDK 回调依赖的 support 兼容 shim（manifest FileProvider 已 keep，
# 这里兜底防止参数签名被裁剪）
-keep class android.support.v4.content.** { *; }

# 保留行号信息便于线上崩溃归因（不做完整混淆映射回传）
-keepattributes SourceFile,LineNumberTable

# 以下为「可选依赖」缺失告警：类不在 classpath 上但相关代码路径不会执行，
# R8 需要 dontwarn 才能继续收缩。
# Flutter 嵌入层的 Play Store 延迟组件（未接入 Play Core 动态分发）
-dontwarn com.google.android.play.core.**
# QQ OpenSDK（lite jar）的 okhttp 网络层（运行时缺失时回退内置 HTTP）
-dontwarn okhttp3.**
