import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名。密钥与口令都不入库：本机放 `flutter/android/key.properties`（已 gitignore），
// CI 从仓库 secrets 还原出同名文件。
//
// 缺这份文件时回落到 debug 签名，好让贡献者不做额外准备也能构建。但 debug 签名在 CI 上
// 每次运行都是**新生成**的密钥，用户装过旧版本就覆盖不上去（Android 报「应用未安装」，
// 必须先卸载），所以正式发布必须提供 key.properties。
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        FileInputStream(file).use { load(it) }
    }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "app.agentlink.companion"
    compileSdk = flutter.compileSdkVersion
    // 固定到本机已安装的 NDK。Flutter 3.41.8 默认要求的 28.2.13676358 在当前
    // 网络下无法从 dl.google.com 下载（实测约 80KB/s，整个包需数小时），而本机
    // ~/Library/Android/sdk/ndk/29.0.14206865 已完整可用。
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "app.agentlink.companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "AgentLink: 未找到 android/key.properties，本次发布使用 debug 签名。" +
                        "这样构建出的包无法覆盖安装已发布版本，仅适合本地验证。"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
