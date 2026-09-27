allprojects {
    repositories {
        // Kotlin 2.2.20+ 起 kotlin-compiler-embeddable 的 jar 在 Maven Central
        // 上被 301 重定向到 GitHub Releases；GitHub 不可达的网络环境下跟随
        // 重定向会以连接错误终止整个解析（不会回退到后续仓库）。将 JetBrains
        // Space 官方仓库置于最前（仅解析 org.jetbrains.kotlin 组），让元数据
        // 与 jar 均直接命中，绕开重定向。
        maven("https://maven.pkg.jetbrains.space/kotlin/p/kotlin/dev") {
            content {
                includeGroup("org.jetbrains.kotlin")
            }
        }
        google()
        mavenCentral()
    }
    configurations.all {
        resolutionStrategy {
            // Xiaomi Civi 4 Pro 等机型上 ExoPlayer 间歇性起播卡死：
            // just_audio 0.10.6 底层捆绑的 media3 1.4.1 偏旧，统一强制
            // 到最新 1.11.1（media3 对 ExoPlayer 2.x 的继任实现，持续
            // 修复各 OEM ROM 的解码/AudioTrack 兼容问题）。
            // force 仅替换已解析依赖的版本，未被引用的组件不受影响。
            force("androidx.media3:media3-common:1.11.1")
            force("androidx.media3:media3-exoplayer:1.11.1")
            force("androidx.media3:media3-exoplayer-hls:1.11.1")
            force("androidx.media3:media3-exoplayer-dash:1.11.1")
            force("androidx.media3:media3-exoplayer-smoothstreaming:1.11.1")
            force("androidx.media3:media3-extractor:1.11.1")
            force("androidx.media3:media3-datasource:1.11.1")
            force("androidx.media3:media3-database:1.11.1")
            force("androidx.media3:media3-decoder:1.11.1")
            force("androidx.media3:media3-ui:1.11.1")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // 强制所有 Android 库模块（含 file_picker 等插件）compileSdk 为 36，
    // 避免 flutter_plugin_android_lifecycle 要求 36 而插件默认用 34 导致构建失败。
    // 注意：afterEvaluate 必须在 evaluationDependsOn(":app") 触发求值之前注册。
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileSdkVersion(36)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
    // 统一所有插件子项目的 compileSdk，避免个别插件（如 audio_session 的 34）触发 SDK 自动下载
    fun forceCompileSdk() {
        extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
        }
    }
    if (project.state.executed) {
        forceCompileSdk()
    } else {
        afterEvaluate { forceCompileSdk() }
    }
}

// tencent_kit 6.2.0 捆绑的 open_sdk jar 方法签名引用已移除的
// android.support.v4.app.Fragment，AndroidX 工程下编译报「找不到
// android.support.v4.app.Fragment」；注入编译期桩 jar 提供该类
// （仅作用于 tencent_kit 模块，pub get 重装插件后仍生效）。
subprojects {
    if (name == "tencent_kit") {
        afterEvaluate {
            val stubJar = rootProject.file("stubs/android-support-v4-fragment.jar")
            if (stubJar.exists()) {
                dependencies.add("vendorImplementation", files(stubJar))
                println("[stub] injected android.support.v4.app.Fragment stub into tencent_kit")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
