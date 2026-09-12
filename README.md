# 密信（Mx）— 全平台群聊客户端

基于 [ntfy](https://ntfy.sh) 协议构建的跨平台群聊应用，功能对齐原 Android 项目（`io.heckel.mx`）与桌面项目（Wails/Go），
用 **Flutter 单套代码** 同时覆盖：

| 平台 | 产物 | 状态 |
| --- | --- | --- |
| Android | `.apk`（**仅 arm64-v8a**） | ✅ 已构建（**17.7 MB**，原 50.2 MB，**-65%**） |
| Windows | `.exe`（含全部依赖的发布目录） | ✅ 已构建（28 MB） |
| Web | 静态站点（可任意静态托管） | ✅ 已构建（**31.9 MB**，原 41 MB，-20%） |
| Linux | 可执行文件 + bundle 目录 | ⏳ 配置就绪，需在 Linux 主机构建（见下） |
| macOS | `.app` | ⏳ 配置就绪，**必须在 macOS 上构建**（见下） |
| iOS | `.ipa` / `.app` | ⏳ 配置就绪，**必须在 macOS 上构建**（见下） |

> ### 平台构建的硬性限制
>
> Flutter 的**编译产物与宿主系统强绑定**，这是设计上的限制，不是配置问题：
>
> | 平台 | 能否在 Windows 上构建 | 原因 |
> | --- | --- | --- |
> | Linux | ❌ | 需 Linux 工具链（clang、GTK3、ninja），Flutter 明确拒绝跨平台构建 |
> | macOS | ❌ | 需 Xcode 与 macOS SDK（Cocoa/AppKit） |
> | iOS | ❌ | 需 Xcode、iOS SDK、以及**代码签名证书**（Apple 开发者账号） |
>
> 因此本机（Windows）能交付的是 **Android / Windows / Web** 三个平台，
> Linux 可经 WSL 构建。macOS 与 iOS 的工程配置已全部就绪
> （含 Info.plist 权限、entitlements 沙箱权限、ATS 明文 HTTP 例外），
> **在任意一台 Mac 上执行一条命令即可出包，无需再改配置**。

### 本次已产出的包

```text
dist\
├── android\密信-arm64-v8a-release.apk   17.7 MB   io.heckel.mx / 密信 / minSdk 26
├── windows\                             28 MB     mx.exe + 全部运行库
└── web\                               31.9 MB     静态站点，任意静态服务器可托管
```

Windows 产物已实测启动（`mx.exe` 进程正常驻留）；APK 已通过 `aapt2` / `apksigner` 校验：

```text
package: name='io.heckel.mx'  versionCode='1'  versionName='1.0.0'
minSdkVersion: 26    targetSdkVersion: 36    compileSdkVersion: 36
application-label: '密信'
native-code: 'arm64-v8a'                      ← 仅 64 位 ARM，单一架构
Verified using v2 scheme (APK Signature Scheme v2): true
```

> ⚠️ **当前用的是 debug 签名**（`CN=Android Debug`）。`android/app/build.gradle.kts` 的
> `hasReleaseSigning()` 会在存在 `android/key.properties` 时自动切到正式签名，
> 没有则回退 debug 以保证开箱可用。**上架前请补上 `key.properties`**，
> 否则后续换正式密钥会因签名不一致而无法覆盖安装。

> ⚠️ **这个包只支持 64 位 ARM 设备。** 近几年的 Android 真机（含全部国产机型）都是
> arm64-v8a，可直接安装。但极老的 32 位机型、以及 Intel/AMD 处理器上的模拟器装不上。
> 需要兼容时用
> `.\scripts\build-release.ps1 -Only android -TargetPlatform 'android-arm,android-arm64'`
> 重新构建（体积约 32 MB）。

### 体积优化说明

三个平台的包都做过针对性瘦身，原则是**只删确定零引用的东西**，不碰运行时按需加载的资源。

**Android：全架构 50.2 MB → 仅 arm64 17.7 MB（-65%）。**
APK 体积的 **95% 是 native 库**，且几乎全是 Flutter 引擎本体：

| 组成 | 解压后 | 占比 |
| --- | --- | --- |
| `lib/arm64-v8a/libflutter.so` | 11.20 MB | 63.3% |
| `lib/arm64-v8a/libapp.so` | 5.44 MB | 30.7% |
| `lib/arm64-v8a/libdartjni.so` | 0.13 MB | 0.7% |
| `lib/arm64-v8a/libdatastore_shared_counter.so` | 0.01 MB | 0.1% |
| dex 代码 + assets + res + 签名 | 约 0.9 MB | 5.2% |

`libflutter.so` 是 Flutter 引擎运行时，`libapp.so` 是应用代码的 AOT 产物——**这两个都不可删减**。
所以这里没有"挤水分"的空间，只能靠减少架构数量。

优化分两层，**缺一不可**：

1. **Flutter 层**：`--target-platform android-arm64` 剔除另两种架构的 `libflutter.so`
   与 `libapp.so`（原本 x86_64 引擎 18.1 MB + v7a 引擎 14.3 MB）。
2. **Gradle 层**：`ndk.abiFilters` + `packaging.jniLibs.excludes` 剔除插件带来的其它 ABI。

> ⚠️ **为什么必须两层都做**：`--target-platform` **只控制 Flutter 引擎自己的 `.so`**，
> 管不到第三方插件从 AAR 里带进来的 native 库。实测 `shared_preferences` 的 DataStore
> 后端会带 `libdartjni.so` / `libdatastore_shared_counter.so` 的 v7a 与 x86_64 变体——
> 只做第一层时，包里仍会残留 `armeabi-v7a` 和 `x86_64` 两个目录（多占 0.2 MB），
> 且 `aapt2` 的 `native-code` 字段仍会列出这三种架构。

> ⚠️ `abiFilters` 与 `--split-per-abi` **互相冲突**（两种机制都在决定 ABI 集合，
> 同时用会导致产物错乱）。本项目固定出单一 arm64 通用包，故可安全使用；
> 若将来要拆包，必须先移除 `build.gradle.kts` 里的这段配置。

**Web：删调试符号 + 跳过 wasm 预检 → 40.1 MB 降到 31.9 MB（-20%）。**
`build/web` 下 6 个 `.symbols` 文件（共 8.2 MB）是 wasm/js 的符号表，只在分析崩溃栈
时才有用，运行时完全不加载——全量扫描产物内所有 `.js` 后确认零引用，可安全删除。
另用 `--no-wasm-dry-run` 跳过 wasm 兼容性预检（本项目渲染器是 canvaskit，
见 `flutter_bootstrap.js` 的 `renderer` 字段，不依赖 wasm 运行时），
构建耗时从 41.7s 降到 6.1s。

> ⚠️ `canvaskit/` 下的多渲染器变体（`chromium/`、`webparagraph/`、`skwasm*`、`wimp`）
> **不可删**——它们在 `flutter.js` / `flutter_bootstrap.js` 里被运行时按浏览器能力动态引用，
> 删掉会让部分浏览器白屏。

**Windows：无可优化空间。** 28 MB 里 `flutter_windows.dll` 占 20.29 MB，是 Flutter 引擎
本体，属于必需运行时；其余是两个插件 DLL 与 `mx.exe`（91 KB）。

### 构建 Linux 包

需在 Linux 主机或 WSL 里执行（Flutter 不允许跨平台构建 Linux 产物）。

**前置依赖**（Debian/Ubuntu 系）：

```bash
sudo apt update && sudo apt install -y \
    clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
    libstdc++-12-dev
```

**构建**：

```bash
flutter pub get
./scripts/mklinks-linux.sh          # 可选：若报插件链接错误再执行
flutter build linux --release
# 产物：build/linux/x64/release/bundle/
#   ├── mx            ← 可执行文件
#   └── lib/          ← 依赖库，必须与 mx 一起分发
```

把 `bundle/` 整个目录拷到 `dist/linux/` 即可。**注意别只拷 `mx` 那一个文件**——
它依赖同目录 `lib/` 下的库，单独拿走会启动失败。

> RHEL/Rocky 系（如本机的 WSL Rocky-9）把上面的 `apt` 换为：
> `sudo dnf install -y clang cmake ninja-build pkgconf-pkg-config gtk3-devel liblzma-devel`
> 另需 GTK3 运行时：`sudo dnf install -y gtk3`

### 构建 macOS 包

**必须在 macOS 上执行**（需 Xcode 与 macOS SDK）。

```bash
# 1. 装 Xcode 命令行工具
xcode-select --install

# 2. 拉依赖并构建
flutter pub get
flutter build macos --release
# 产物：build/macos/Build/Products/Release/密信.app
```

分发有两种形态：

```bash
# 形态 A：直接给 .app（对方拖进"应用程序"即可，首次打开需右键→打开）
#         但未签名的 .app 在对方机器上会被 Gatekeeper 拦截

# 形态 B：打成 dmg（更正式，需先安装 create-dmg）
brew install create-dmg
create-dmg \
  --volname "密信" \
  --window-size 600 400 \
  --icon-size 100 \
  --app-drop-link 450 185 \
  "dist/macos/密信-1.0.0.dmg" \
  "build/macos/Build/Products/Release/密信.app"
```

> **签名与公证**：当前工程用 debug 签名占位。要分发给他人，需 Apple 开发者账号
> （$99/年）配置 `DEVELOPMENT_TEAM` 并做 notarization，否则对方需手动绕过 Gatekeeper
> （右键 → 打开，或 `xattr -dr com.apple.quarantine /Applications/密信.app`）。
> 自用或内部分发可忽略这一步。

### 构建 iOS 包

**必须在 macOS 上执行**，且需要 **Apple 开发者账号**才能装到真机或上架。

```bash
# 1. 装 Xcode（App Store 完整版，非仅命令行工具）
# 2. 拉依赖
flutter pub get

# 3a. 无签名构建（只验证能否编译通过，产物不能装真机）
flutter build ios --release --no-codesign

# 3b. 真机 / 上架
#     先用 Xcode 打开 ios/Runner.xcworkspace 配置签名团队：
#       Runner → Signing & Capabilities → Team 选你的开发者账号
#     然后：
flutter build ipa --release
# 产物：build/ios/ipa/密信.ipa
```

**上架 App Store 还需**：
- 在 [App Store Connect](https://appstoreconnect.apple.com) 创建应用记录（Bundle ID 需与 `io.heckel.mx` 一致）
- 准备 App 图标（`ios/Runner/Assets.xcassets/AppIcon.appiconset/`，需全尺寸）、启动图、隐私政策链接
- 通过 Xcode Organizer 或 `xcrun altool` 上传，走 TestFlight 内测后再提交审核

> ⚠️ **iOS 的 ATS 例外已被显式开启**（`Info.plist` 的 `NSAllowsArbitraryLoads`），
> 因为默认服务端是明文 HTTP。**上架时 Apple 会要求说明理由，且可能被拒。**
> 正式提交前建议把服务端换成 HTTPS，并删除该配置段。

---

## 功能

- **群聊管理**：创建带名称的群聊（本地生成 64 字符随机群聊 ID）、复制群聊 ID、通过二维码或链接邀请他人加入。
- **消息收发**：文本、Emoji 快捷输入、优先级（最低～紧急）、标签；长连接实时接收，断线自动重连。
- **文件与图片**：选择任意文件作为附件发送（单文件上限 1GB），附件后台并发下载（上限 3 个同时）并显示进度条。
- **发送者识别**：每条消息带 `{"s":senderId,"m":正文}` 信封，接收端据此**权威判定**"这条是不是自己发的"，从而决定气泡靠左还是靠右。
- **多设备同人**：把各设备的「我的唯一标识」改成同一个值，这些设备发出的消息都算「我」。
- **状态可见**：群聊列表里每个群聊都有连接状态指示灯（绿=已连接 / 黄=连接中 / 红=重连中）。
- **主题**：浅色 / 深色 / 跟随系统（Material 3）。

---

## 快速开始

### 1. 准备环境

需要 Flutter SDK（本机已装于 `E:\application\flutter`）。

```powershell
# 可选：国内网络下用镜像加速 pub 依赖拉取
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
```

### 2. 拉依赖

```powershell
E:\application\flutter\bin\flutter.bat pub get
```

### 3. 运行（调试）

```powershell
# 桌面窗口
E:\application\flutter\bin\flutter.bat run -d windows

# 浏览器
E:\application\flutter\bin\flutter.bat run -d chrome

# 连接的 Android 设备
E:\application\flutter\bin\flutter.bat run -d <device-id>
```

---

## 构建发布包

### 一键构建（推荐）

```powershell
.\scripts\build-release.ps1
```

脚本会依次构建 Windows、Android、Web，并把产物统一收集到 `dist\`：

```text
dist\
├── windows\      mx.exe 及运行所需全部文件
├── android\      mx-release.apk
├── web\          静态站点（直接丢给任意静态服务器）
└── linux\        （在 Linux 上构建后放入）
```

可选参数：

```powershell
.\scripts\build-release.ps1 -SkipWeb          # 跳过 Web
.\scripts\build-release.ps1 -Only android     # 只构建 Android
```

脚本在构建前会自动准备插件链接（见下方「环境注意事项」第 1 条），无需手工介入。
若只想单独修复链接，可执行：

```powershell
# Windows：为 windows 与 linux 两个平台预建插件链接
powershell -ExecutionPolicy Bypass -File .\scripts\mklinks.ps1
```

Linux 主机上对应的脚本是 `scripts/mklinks-linux.sh`。

### 手动构建

```powershell
# Windows（发布版）
E:\application\flutter\bin\flutter.bat build windows --release

# Android APK（发布版，推荐：仅 arm64，17.7 MB）
# 注意：Gradle 层已配置 abiFilters，这里必须与之一致，否则插件 native 库仍会漏进来
E:\application\flutter\bin\flutter.bat build apk --release --target-platform android-arm64

# Android APK，兼容老 32 位机型（约 32 MB）
# 用这个之前，要先移除 android/app/build.gradle.kts 里的 ndk.abiFilters，否则会错乱
E:\application\flutter\bin\flutter.bat build apk --release --target-platform android-arm,android-arm64

# Web（推荐带上 --no-wasm-dry-run，省一次完整编译）
E:\application\flutter\bin\flutter.bat build web --release --no-wasm-dry-run

# Linux（仅在 Linux/WSL 环境可用）
flutter build linux --release

# macOS（仅在 macOS 可用）
flutter build macos --release

# iOS（仅在 macOS 可用，上架需配签名团队）
flutter build ios --release --no-codesign
flutter build ipa --release
```

> 建议直接用脚本，ABI 参数与 Gradle 配置的一致性由它维护：
> `.\scripts\build-release.ps1 -Only android`（默认 arm64）
>
> Android 构建耗时较长（首次全量编译约 22 分钟，增量约 40 秒，主要是插件编译与 dex 合并）。
> 加 `-v` 可看详细进度；`build\app\outputs\flutter-apk\` 下的产物不带进度输出，
> 中途怀疑卡住时可查 `build\` 目录的文件时间戳与 Gradle daemon 的 CPU 占用。

### 环境注意事项

本机（Windows + Flutter 3.47.4）构建时踩到过四个环境问题，已固化到脚本或配置里，这里记录成因备查。

**1. 插件链接创建失败**

现象：`flutter build windows` 报
`PathNotFoundException: Cannot create link ... .plugin_symlinks\<插件名>`。

成因：Flutter 的 `_createPlatformPluginSymlinks` 在 `link.existsSync()` 返回 false 时才会
调用 `createSync`；而本机环境下该调用会间歇性失败，直接把构建打断。注意
`flutter build windows` 会**同时**为 windows 和 linux 两个平台准备插件目录，所以两边都要建。

处置：`scripts\build-release.ps1` 在构建前调用 `Initialize-PluginLinks`，从
`.flutter-plugins-dependencies` 读清单并以 **junction** 形式预建链接
（目录符号链接在 Windows 上需要管理员权限或开发者模式，junction 不需要）。
构建报链接错误时，可单独执行 `scripts\mklinks.ps1` 补齐。

**2. Gradle 不再联网下载**

`android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 已指向**本机已装的
Gradle 归档**，彻底离线，不再访问 `services.gradle.org`：

```properties
distributionUrl=file\:/E:/application/java/gradle-9.7.1-bin.zip
```

`E:\application\java\gradle-9.7.1-bin.zip`（151 MB）与本机 `E:\application\java\gradle-9.7.1`
同源，wrapper 要求的顶层目录 `gradle-9.7.1/` 结构一致。换机器或移动该文件时，把这一行改回
官方 URL 或镜像即可。验证：

```powershell
cd D:\code\mx\android
.\gradlew.bat --version     # 应输出 Gradle 9.7.1 / Kotlin 2.4.0，瞬时返回、无网络请求
```

`android/settings.gradle.kts` 与 `android/build.gradle.kts` 的 repositories 另加了阿里云镜像，
供依赖（AGP、插件等）加速。

**3. `flutter test` 无法运行**

现象：任何测试都报
`Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`。

成因：Dart 3.13 的 `WebSocket.connect` 会先发一次**不带 `Upgrade` 头**的探测请求，
拿 200 后再发真正的升级请求；而 Flutter 3.47.4 的测试 harness 用 `_server.first`
取第一个请求做 `WebSocketTransformer.upgrade()`，正好取到那条探测请求，于是握手失败。
这是 SDK 与工具链之间的版本兼容问题，**与应用代码无关**。

处置：换用 Flutter stable 的稍早版本即可。构建产物不受影响——`flutter build`
不走这条 WebSocket 通道。

**4. Gradle daemon 锁冲突（多 Gradle 版本共存时）**

现象：构建报
`java.io.FileNotFoundException: ...\caches\journal-1\journal-1.lock (拒绝访问。)`，
且 `./gradlew.bat --stop` 回你 "No Gradle daemons are running"。

成因：Android Studio 会用**它自己的 Gradle 版本**起一个 daemon（本机为 9.3.1），而项目的
wrapper 用的是 9.7.1。两者共用同一个 `GRADLE_USER_HOME`（本机 `D:\app_cache\gradle_cache`）
时，会在 `caches\journal-1` 上争抢同一把文件锁。

关键点：**`gradlew --stop` 只停自己版本的 daemon**，对 9.3.1 那个无效——所以它才会
报 "No Gradle daemons are running"，让你误以为没有 daemon 在跑。

处置：拿**对应版本的 Gradle 发行版**发 stop 请求即可，无需关闭 Android Studio。
wrapper 已解压在 `GRADLE_USER_HOME\wrapper\dists\` 下，直接用它：

```powershell
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
$g = "$env:GRADLE_USER_HOME\wrapper\dists\gradle-9.3.1-all\*\gradle-9.3.1\bin\gradle.bat"
& (Resolve-Path $g) --stop        # 输出 "1 Daemon stopped" 即成功
```

daemon 是**空闲常驻**的（只在做周期性健康检查），从它的日志
`GRADLE_USER_HOME\daemon\<版本>\daemon-<pid>.out.log` 可确认未在执行构建任务。
停止后锁由内核异步回收，等 2~3 秒再构建。

> 更省事的根治办法：给命令行构建单独指定一个 `GRADLE_USER_HOME`，
> 与 Android Studio 彻底隔离。代价是依赖缓存（本机 1.9 GB）要重新下载一次，
> 所以没默认启用。

---

## 配置

### 默认服务器

默认服务端写在 `lib/core/constants.dart`：

```dart
const String kDefaultServer = 'http://111.229.201.94:48081';
const String kDefaultUser   = 'admin';
const String kDefaultPass   = 'wangchaojun';
```

界面里「设置 → 服务器与认证」可以临时改（对新建群聊生效）。

> 生产环境建议把服务地址换成 HTTPS —— 明文 HTTP 在移动网络下等于把消息和密码公开挂在链路上。

### 我的唯一标识

存在应用数据目录的 `mx-data/mx.senderId.json`。桌面端也可以直接用环境变量覆盖：

```powershell
$env:MX_SENDER_ID = "aabbccddeeff0011"
```

想让手机和电脑都算「同一个人」，把两边的标识填成同一个 16 位十六进制值即可。

---

## 协议要点（与另两端保持一致）

线格式是三端互通的契约，改动需同步 Android 与 Go 端：

### 信封

发送时正文被包成：

```json
{"s":"aabbccddeeff0011","m":"用户真正输入的文本"}
```

- `s`：16 位十六进制发送方标识
- `m`：用户原文

接收端先尝试解信封；解不出来就当作普通正文原样显示（不会吞掉用户手写的 JSON）。

### HTTP 接口

| 用途 | 方法与路径 |
| --- | --- |
| 发布 | `POST /<topic>`，正文走 body，元数据走 `X-Title` / `X-Priority` / `X-Tags` / `X-Message` / `X-Filename` 等头 |
| 订阅长连接 | `GET /<topic>/json?since=<id\|all\|none>`，逐行 NDJSON |
| 一次性轮询 | `GET /<topic>/json?poll=1&since=<id>` |
| 鉴权探测 | `GET /<topic>/auth` |
| 健康检查 | `GET /v1/health` |

附件消息：文件字节走 POST body，正文退回 `?message=` query 参数（因为 body 已被占用）。

### 事件类型

`message`（正常消息）、`open`（连接就绪）、`keepalive`（心跳，忽略）、
`message_delete` / `message_clear`（服务端删除事件）。

---

## 项目结构

```text
lib/
├── main.dart                  启动入口（含初始化失败的兜底界面）
├── core/
│   ├── constants.dart         全平台统一常量（服务端、优先级、上限、topic 校验）
│   ├── envelope.dart          {"s":..,"m":..} 信封打包/解包/归属判定
│   ├── models.dart            ntfy 协议数据模型
│   ├── ntfy_api.dart          HTTP 客户端（发布/订阅/轮询/鉴权/下载，含 Web 分支）
│   ├── store.dart             跨平台持久化（分片 JSON，原子写）
│   └── hub.dart               订阅连接管理、重连退避、附件后台下载
└── ui/
    ├── theme.dart             调色板与头像派生
    ├── home_page.dart         自适应主容器（宽屏侧栏 / 窄屏两页）
    ├── group_list_page.dart   群聊列表 + 连接状态灯
    ├── chat_page.dart         气泡消息流 + 输入区
    ├── add_group_sheet.dart   创建/加入群聊 + 邀请二维码
    └── settings_page.dart     标识/二维码/扫码/服务器/群聊管理
```

---

## 存储说明

没有使用 SQLite，改用**分片 JSON 文件**：

- 每个群聊（服务器+主题）一个分片，避免单文件膨胀
- 每个分片只保留最近 2000 条消息
- 写入走「临时文件 + rename」，断电或崩溃不会留下半个文件
- Web 平台落到 `localStorage`，其余平台落到应用数据目录

取舍：牺牲了 SQL 查询能力，换来全平台零额外依赖。本应用的查询只有「按群聊取最近 N 条」，内存过滤足够。

---

## 已知限制

- **Web 端附件**：受浏览器 CORS 限制，附件不做预下载，点开时交给浏览器直链访问。
- **扫码识别**：桌面端依赖系统里的 `zbarimg`（ZBar 工具）。识别不了时会提示手动粘贴群聊 ID，不会静默失败。
- **Android 后台保活**：清单里已声明前台服务与唤醒锁权限，但当前版本未实现原生前台服务 —— 长时间后台挂起后系统可能回收连接，回到前台会自动重连。

---

## License

Apache License 2.0（沿用上游 ntfy-android 的许可协议）。
