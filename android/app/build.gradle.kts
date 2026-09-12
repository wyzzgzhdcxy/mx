import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.heckel.mx"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.heckel.mx"
        // 对齐原 Android 项目：最低 Android 8.0（API 26）
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 默认用 debug 签名，保证 `flutter build apk --release` 开箱可用。
            // 要出正式包时在 android/key.properties 里配置自己的签名，
            // 下面的 signingConfigs.release 会自动接管。
            signingConfig = if (hasReleaseSigning()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    signingConfigs {
        if (hasReleaseSigning()) {
            create("release") {
                val props = loadKeyProperties()
                storeFile = file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }
}

/// 是否存在 android/key.properties（发布签名配置）。
fun hasReleaseSigning(): Boolean {
    return rootProject.file("key.properties").exists()
}

/// 读取 android/key.properties。
fun loadKeyProperties(): Properties {
    val props = Properties()
    rootProject.file("key.properties").inputStream().use { props.load(it) }
    return props
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
