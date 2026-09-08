# XY Music Mobile · Agent 习惯与构建要求

以下要求为用户长期约定，执行构建相关任务时无需用户再次提醒。

## 构建硬性要求（每次构建必须满足）

1. **压缩代码**：release 构建保持 R8 代码压缩 + 资源压缩
   （`android/app/build.gradle.kts` 中 `isMinifyEnabled = true`、
   `isShrinkResources = true`，不可关闭）。
2. **只交付 arm64 安装包**：`flutter build apk --release --split-per-abi`，
   只取 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，
   不交付通用包（避免多 ABI 引擎导致体积膨胀）。
3. **安装包大小 ≤ 20MB**：构建完成后检查 arm64 APK 体积，
   超过 20MB 必须排查（常见原因：未开 R8、误打通用包、新增大体积资源/字体）。
4. **产物命名与位置**：复制到 `releases/XY Music_<版本号>_arm64.apk`，
   版本号写入 `pubspec.yaml` 的 `version:` 字段（构建号 +1 递增），
   发布前向用户报告实际体积。

## 沙盒构建环境（Linux）

| 项 | 路径 / 说明 |
|----|------------|
| Flutter SDK | `/opt/flutter`（3.44.9 stable，匹配 Dart `^3.12.2` 约束） |
| Android SDK | `/opt/android-sdk`（cmdline-tools + platforms;android-36 + build-tools） |
| JDK | Java 25（mise shim，Gradle 9.1 兼容） |
| Rust 核心 `.so` | 预编译在 `android/app/src/main/jniLibs/`（改 Rust 代码才需重编） |
| 签名 | 项目根 `debug.keystore`（正式签名，build.gradle.kts 显式引用） |

环境被重置时按以下步骤恢复（约 10 分钟）：

```bash
# 1. Flutter SDK
curl -sL -o /tmp/flutter.tar.xz \
  https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.44.9-stable.tar.xz
tar -xJf /tmp/flutter.tar.xz -C /opt && rm /tmp/flutter.tar.xz

# 2. Android SDK
mkdir -p /opt/android-sdk/cmdline-tools && cd /tmp
curl -sL -o cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q cmdtools.zip -d /opt/android-sdk/cmdline-tools
mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest
yes | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null
/opt/android-sdk/cmdline-tools/latest/bin/sdkmanager \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0"

# 3. 构建
export PATH=/opt/flutter/bin:$PATH
cd /workspace/XY-Music-Mobile
flutter pub get
flutter build apk --release --split-per-abi
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "releases/XY Music_<版本号>_arm64.apk"
```

## 网络（代理，必读）

沙盒出网必须走本地代理 `127.0.0.1:18080`（curl 等工具读
`HTTP_PROXY/HTTPS_PROXY` 环境变量即可）。**Gradle daemon 不读代理环境
变量**，缓存被清空后首次构建下载依赖会报
`Plugin ... was not found in any of the following sources`。此时必须写
`~/.gradle/gradle.properties`：

```properties
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=18080
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=18080
systemProp.http.nonProxyHosts=localhost|127.0.0.1
systemProp.https.nonProxyHosts=localhost|127.0.0.1
```

写完后 `gradle --stop` 重启 daemon 再构建。Gradle wrapper 发行包若下载
卡住，手动下载到 `~/.gradle/wrapper/dists/` 对应目录：

```bash
curl -sL -o $D/gradle-9.1.0-all.zip \
  https://mirrors.cloud.tencent.com/gradle/gradle-9.1.0-all.zip
```

依赖仓库（google()/mavenCentral/plugins.gradle.org）经代理均可访问；
`~/.gradle/caches/modules-2` 依赖缓存被清空时首次构建需重新下载，
耗时约 20 分钟属正常。

## 其他长期约定

- 回复与代码注释使用中文；构建产物版本号以用户当次说明为准。
- 本项目路径全 ASCII，可直接 `flutter build apk`，无需 Windows 端的
  robocopy 中转（那是用户本机中文路径的限制，见 `scripts/build-release.ps1`）。
