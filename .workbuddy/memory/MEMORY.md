# 密信（Mx）Flutter 项目 —— 长期约定

## 项目定位
Flutter 单套代码的全平台群聊客户端，基于 ntfy 协议。
是对原 Android 项目（`D:\code\mx-android`）与桌面项目（`D:\code\mx_desktop`，Wails/Go）的重写。
**协议行为以安卓端为准**。

## 关键路径
- Flutter SDK：`E:\application\flutter\bin\flutter.bat`（用户环境里 flutter 不在 PATH 上）
- 产物目录：`dist\{windows,android,web}`，由 `scripts\build-release.ps1` 生成
- 包名 `io.heckel.mx`，应用名「密信」，minSdk 26（对齐原安卓项目）

## 协议常量（改动需三端同步）
- 默认服务器 `http://111.229.201.94:48081`，凭据 admin / wangchaojun
- 信封：`{"s":"<16位小写hex>","m":"<原文>"}`，`s` 权威判定消息归属
- 群聊 ID：64 字符 `A-Za-z0-9`，服务端规则 `^[-_A-Za-z0-9]{1,64}$`
- 重连退避 `[5,10,15,20,30,45,60,120]` 秒（对齐 Android `JsonConnection.RETRY_SECONDS`）
- 附件上限：内存通道 15MB / 磁盘通道 1GB / 下载 100MB / 并发 3

## 构建约定
- **构建前必须先准备插件链接**（见当日记忆的踩坑 #1）。`build-release.ps1` 已内置，
  手工构建时先跑 `scripts\mklinks.ps1`。
- **.ps1 脚本一律纯 ASCII**。本机 PowerShell 5.1 按 GBK 读文件，中文注释会导致解析失败。
- 网络类问题的第一嫌疑是**本机的 PAC 自动代理**（`127.0.0.1:10811/pac`）。
  Dart 侧已用 `findProxy = 'DIRECT'` 规避；Gradle/pub 侧走国内镜像。
- **Gradle 已本地化**：wrapper 的 `distributionUrl` 指向
  `file:/E:/application/java/gradle-9.7.1-bin.zip`，完全离线。
  换机器/移动该文件时改回官方 URL 或镜像。
- **用 PowerShell 工具跑 flutter 命令**，不要在 Bash 工具里跑——Flutter 探测设备时会调
  `wsl.exe`，该程序在沙箱黑名单上，Bash 通道会被直接拦掉。
- **优化后的推荐构建参数**：
  - Android：`--target-platform android-arm,android-arm64`（剔除 x86_64 引擎库，-36% 体积）
  - Web：`--no-wasm-dry-run`（本项目 renderer=canvaskit，跳过无用的 wasm 预检）
- **不要碰 `canvaskit/` 下的多渲染器变体**（`chromium/`、`webparagraph/`、`skwasm*`、`wimp`）
  与 Web 产物的 `.symbols`（后者可删，前提是先全量扫描 `.js` 确认零引用）。

## 存储
放弃 SQLite，用分片 JSON（每群聊一分片、保留最近 2000 条、原子写）。
Web 端落 localStorage。原因：避免 Web 平台的 WASM 分支，三端共用同一套代码。

## 已知遗留
- `flutter test` 在本机 Flutter 3.47.4 下无法运行（Dart 3.13 与 harness 的 WebSocket
  握手不兼容，已定位为工具链问题）。单元测试 `test/protocol_test.dart` 尚未执行验证，
  换 Flutter 版本后应补跑。
- Linux 产物需在 Linux 主机构建（Flutter 限制）。
- **APK 目前是 debug 签名**（`CN=Android Debug`）。补 `android/key.properties` 即自动切
  正式签名；上架前必须补，否则后续换密钥会因签名不一致无法覆盖安装。
