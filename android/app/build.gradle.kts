plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.xymusic.mobile"
    // file_picker 依赖的 flutter_plugin_android_lifecycle 要求 compileSdk >= 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xymusic.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // record 7.x 的 Android PCM 流采集要求 API 23+
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 只交付 arm64：脚本用 --split-per-abi 按 ABI 拆包，arm64 分包天然
        // 只含 arm64-v8a 的 jniLibs/AAR 原生库。这里不能再设 ndk abiFilters，
        // 否则与 splits abi 配置冲突（Gradle 直接报错）。
    }

    signingConfigs {
        // 显式使用项目根目录的 debug.keystore 签名（用户提供的正式签名，
        // beta1 起的所有版本均用它），避免 Gradle 回退到 ~/.android/
        // 下自动生成的临时 debug keystore 导致签名不一致、无法覆盖安装。
        create("release") {
            storeFile = rootProject.file("../debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // Signing with the debug keys, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("release")
            // R8 代码压缩 + 资源压缩：裁剪未使用的 Java/Kotlin 字节码与 Android
            // 资源，控制 APK 体积（QQ OpenSDK 的 keep 规则由 tencent_kit 的
            // consumer-vendor-rules.pro 自动带入）。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        jniLibs {
            // 压缩打包原生库（默认不压缩以加快加载），可显著减小 APK 体积
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 禁用 lint 关键检查 task（避免构建时从 dl.google.com 下载 lint 依赖超时）
tasks.configureEach {
    if (name.startsWith("lintVital")) {
        enabled = false
    }
}
