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
        // ABI 过滤交给 --split-per-abi：每个分架构 APK 天然只含单 ABI 原生库
        // （此前在此处加 ndk abiFilters 会与 splits 配置冲突，AGP 直接报错）。
    }

    buildTypes {
        release {
            // Signing with the debug keys, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
