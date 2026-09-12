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

        // 只出 arm64-v8a。
        //
        // 为什么在 Gradle 层还要再过滤一次：Flutter 的 --target-platform 只管
        // Flutter 引擎自己的 .so（libflutter.so / libapp.so），管不到第三方插件
        // 从 AAR 里带进来的 native 库。实测 shared_preferences 的 DataStore 后端
        // 会带 libdartjni.so / libdatastore_shared_counter.so 的 v7a 与 x86_64
        // 变体，白占约 0.2 MB。
        //
        // 注意：abiFilters 与 --split-per-abi 同用会让产物错乱（两种机制都在
        // 决定 ABI 集合，互相覆盖）。本项目固定出单一 arm64 通用包，故可安全使用；
        // 若将来要改回多架构拆包，务必先移除这段。
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    // 双保险：abiFilters 理论上已挡住依赖里的其他 ABI，但插件若通过非标准路径
    // （如打包在 assets 或自定义 copy 任务）塞入 .so，仍可能漏进来。
    // 这一层直接在打包时排除，确保产物里只有 arm64-v8a。
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/mips/**",
                "lib/mips64/**",
            )
        }
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
