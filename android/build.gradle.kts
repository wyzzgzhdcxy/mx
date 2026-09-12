allprojects {
    repositories {
        // 国内网络下优先走阿里云镜像，避免直连 google/mavenCentral 超时。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
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
}

// 统一所有子项目的 compileSdk。
//
// 部分插件（如 file_picker 8.3.7）自己声明的 compileSdk 还是 34，而
// flutter_plugin_android_lifecycle 要求依赖方至少编译到 36，AGP 的 AAR 元数据校验
// 会在 checkReleaseAarMetadata 阶段直接失败。这里在所有子项目上强制抬到 36。
// 只抬 compileSdk（允许使用新 API），不动 minSdk/targetSdk，不影响装机范围与运行时行为。
//
// 用反射式属性写入而非直接引用 DSL 类型：插件的 Android 插件是在
// Flutter 的 evaluationDependsOn 之后才 apply 的，编译期拿不到稳定类型。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        val current = runCatching {
            androidExt.javaClass.getMethod("getCompileSdkVersion").invoke(androidExt) as? String
        }.getOrNull()
        val currentNum = current?.removePrefix("android-")?.toIntOrNull()
        if (currentNum == null || currentNum < 36) {
            runCatching {
                androidExt.javaClass
                    .getMethod("setCompileSdkVersion", String::class.java)
                    .invoke(androidExt, "android-36")
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
