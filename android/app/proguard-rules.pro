# 密信（Mx）Android 混淆规则。
#
# Flutter 引擎自身已有默认规则（由 flutter-gradle-plugin 注入），这里只处理
# 本项目依赖的插件在 release 混淆下容易出问题的部分。

# --- shared_preferences ---
# 通过 SharedPreferences 读写，反射调用较少，但保留以防未来引入自定义编解码。
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# --- url_launcher ---
-keep class io.flutter.plugins.urllauncher.** { *; }

# --- file_picker ---
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# --- path_provider ---
-keep class io.flutter.plugins.pathprovider.** { *; }

# --- image_picker ---
-keep class io.flutter.plugins.imagepicker.** { *; }

# --- Flutter 插件注册表 ---
# 插件注册走反射，被裁掉会导致启动即崩。
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# --- 保留注解 ---
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# --- 保留 dart:io 相关的 native 方法签名 ---
-keepclassmembers class * {
    native <methods>;
}
