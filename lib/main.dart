/// 密信（Mx）—— 基于 ntfy 协议的跨平台群聊客户端。
///
/// 全平台同一套代码：Android / Windows / Linux / macOS / iOS / Web。
/// 功能对齐原 Android 项目（io.heckel.mx）与桌面项目（Wails/Go）：
///   - 群聊创建与订阅（64 字符群聊 ID + 本地别名）
///   - 文本 / 表情 / 优先级消息收发
///   - 文件与图片附件（含后台下载与进度）
///   - {"s":..,"m":..} 信封判定"谁发的"（决定气泡左右）
///   - 长连接实时接收 + 断线自动重连
///   - 二维码邀请与扫码加入
library;

import 'package:flutter/material.dart';

import 'core/hub.dart';
import 'core/store.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化存储与连接管理器。任何一步失败都要让用户看到原因，
  // 而不是白屏 —— 这个客户端是常驻工具，静默失败最难排查。
  Store store;
  Hub hub;
  try {
    store = await Store.open();
    hub = Hub(store: store);
    await hub.init();
  } on Exception catch (e) {
    runApp(_FatalApp(error: e.toString()));
    return;
  }

  runApp(MxApp(hub: hub, store: store));
}

class MxApp extends StatelessWidget {
  const MxApp({super.key, required this.hub, required this.store});

  final Hub hub;
  final Store store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '密信',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // 默认跟随系统（与 Android 端"浅色/深色/跟随系统"设置的默认值一致）
      themeMode: ThemeMode.system,
      home: HomePage(hub: hub, store: store),
    );
  }
}

/// 初始化失败时的兜底界面：把错误原样展示，方便定位。
class _FatalApp extends StatelessWidget {
  const _FatalApp({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  '密信启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
