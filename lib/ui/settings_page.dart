/// 设置弹窗。
///
/// 包含：
///  - 我的唯一标识（sender id）展示与复制/修改 —— 多设备填同值即视为"同一个人"
///  - 当前群聊二维码（邀请他人加入）
///  - 扫码识别二维码图片加入群聊
///  - 服务器与认证配置
///  - 群聊管理与删除
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/envelope.dart';
import '../core/hub.dart';
import '../core/models.dart';
import '../core/ntfy_api.dart';
import '../core/store.dart';
import 'add_group_sheet.dart';
import 'theme.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.hub,
    required this.store,
    required this.displayName,
    this.activeTopic,
  });

  final Hub hub;
  final Store store;
  final String Function(String) displayName;
  final String? activeTopic;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  String _myId = '';
  bool _idLoaded = false;
  final _idCtrl = TextEditingController();

  String _server = kDefaultServer;
  String _user = kDefaultUser;
  final _passCtrl = TextEditingController(text: kDefaultPass);

  /// 服务器 / 用户名输入框的控制器：必须持有实例，不能在 build 里 new，
  /// 否则每次重建都会重置光标与内容，用户根本敲不进去字。
  late final TextEditingController _serverCtrl =
      TextEditingController(text: kDefaultServer);
  late final TextEditingController _userCtrl =
      TextEditingController(text: kDefaultUser);

  List<SubRec> _subs = [];

  String _scanError = '';
  String _scanResult = '';
  String? _scanPreviewPath;
  bool _testing = false;
  String _testResult = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _passCtrl.dispose();
    _serverCtrl.dispose();
    _userCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = await widget.store.loadOrCreateSenderId();
    final prefs = await widget.store.getServerPrefs();
    final subs = await widget.store.listSubs();
    if (!mounted) return;
    final server = (prefs['server'] as String?) ?? kDefaultServer;
    final user = (prefs['user'] as String?) ?? kDefaultUser;
    final pass = (prefs['pass'] as String?) ?? kDefaultPass;
    setState(() {
      _myId = id;
      _idCtrl.text = id;
      _idLoaded = true;
      _server = server;
      _user = user;
      _serverCtrl.text = server;
      _userCtrl.text = user;
      _passCtrl.text = pass;
      _subs = subs;
    });
  }

  Future<void> _saveMyId() async {
    final v = _idCtrl.text.trim().toLowerCase();
    if (v.isNotEmpty && !isSenderId(v)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('标识必须是 16 位十六进制字符（0-9 / a-f）'),
        ),
      );
      return;
    }
    final finalId = v.isEmpty ? generateSenderId() : v;
    await widget.store.saveSenderId(finalId);
    widget.hub.senderId = finalId;
    if (!mounted) return;
    setState(() => _myId = finalId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('标识已保存（下次收到消息生效）'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveServer() async {
    await widget.store.setServerPrefs({
      'server': NtfyApi.normalizeBaseUrl(_server),
      'user': _user.trim(),
      'pass': _passCtrl.text,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('服务器配置已保存（对新建群聊生效）'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final api = NtfyApi();
    final ok = await api.health(baseUrl: _server);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = ok ? '连接正常 ✓' : '连接失败 ✗';
    });
  }

  Future<void> _deleteSub(SubRec s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除群聊'),
        content: Text(
          '确定删除「${widget.displayName(s.topic)}」吗？\n本地该群聊的消息也会被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.hub.unsubscribe(s.server, s.topic);
    await _load();
  }

  /// 选择二维码图片并识别。
  Future<void> _pickQrImage() async {
    setState(() {
      _scanError = '';
      _scanResult = '';
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null) {
        setState(() => _scanError = '无法读取该图片');
        return;
      }
      setState(() => _scanPreviewPath = path);

      // Flutter 侧没有可靠的纯 Dart 二维码解码库（jsQR 是 JS 侧），
      // 这里给出明确引导，而不是静默失败。
      final payload = await _tryDecodeQr(path);
      if (payload == null) {
        setState(() {
          _scanError = '未能识别二维码。请确认图片清晰，或手动粘贴群聊 ID 加入。';
        });
        return;
      }
      setState(() {
        _scanResult = payload;
        _scanError = '';
      });
    } on Exception catch (e) {
      setState(() => _scanError = '识别失败：$e');
    }
  }

  /// 当前平台可用的二维码解码路径。
  ///
  /// 桌面端可调系统 zbar（若安装）；移动端留给 image_picker + 后续扩展。
  /// 识别不出来时返回 null，由调用方给用户明确提示。
  Future<String?> _tryDecodeQr(String path) async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        // 尝试调用系统 zbarimg（若用户环境里存在）
        final exe = Platform.isWindows ? 'zbarimg.exe' : 'zbarimg';
        final r = await Process.run(exe, ['-q', path]);
        if (r.exitCode == 0) {
          final out = (r.stdout as String).trim();
          if (out.isNotEmpty) return out.split('\n').first.trim();
        }
      }
    } on Exception {
      // 依赖不存在 → 走下面的兜底
    }
    return null;
  }

  Future<void> _joinFromScan() async {
    final parsed = parseQrPayload(_scanResult);
    if (parsed == null) {
      setState(() => _scanError = '识别到的内容不是有效的群聊链接');
      return;
    }
    try {
      await widget.hub.subscribe(
        server: parsed.server,
        topic: parsed.topic,
        creds: NtfyCredentials(user: _user, pass: _passCtrl.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } on NtfyException catch (e) {
      setState(() => _scanError = e.message);
    }
  }

  Future<void> _openReceivedFolder() async {
    if (NtfyApi.kIsWeb) return;
    final dir = await widget.hub.receivedDir();
    if (dir.isEmpty) return;
    final uri = Uri.file(dir);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  const Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (!NtfyApi.kIsWeb)
                    IconButton(
                      tooltip: '打开收到的文件目录',
                      onPressed: _openReceivedFolder,
                      icon: const Icon(Icons.folder_open, size: 20),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _section('我的唯一标识'),
                  Text(
                    _myId.isEmpty
                        ? '正在读取本机标识…'
                        : '当前标识：$_myId'
                            '${_myId == _idCtrl.text.trim() ? '（已生效）' : '（修改后需点保存）'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: _myId.isEmpty ? Colors.orange : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _idCtrl,
                          readOnly: !_idLoaded,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          decoration: const InputDecoration(
                            hintText: '16 位十六进制标识',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '保存',
                        onPressed: _saveMyId,
                        icon: const Icon(Icons.save_outlined),
                      ),
                      IconButton(
                        tooltip: '复制',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _idCtrl.text.trim()),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制到剪贴板'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  if (widget.activeTopic != null) ...[
                    _section('当前群聊二维码'),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: QrImageView(
                          data: buildQrPayload(_server, widget.activeTopic!),
                          size: 160,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        widget.displayName(widget.activeTopic!),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  _section('扫码加入群聊'),
                  const Text(
                    '选择一张二维码图片，识别后自动加入对应群聊。'
                    '（桌面端需要系统里有 zbarimg；识别不了时可手动粘贴群聊 ID）',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  if (_scanPreviewPath != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Image.file(
                        File(_scanPreviewPath!),
                        height: 120,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _pickQrImage,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('选择二维码图片'),
                  ),
                  if (_scanResult.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.black12),
                      ),
                      child: SelectableText(
                        _scanResult,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _scanResult),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                            child: const Text('复制内容'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (parseQrPayload(_scanResult) != null)
                          Expanded(
                            child: FilledButton(
                              onPressed: _joinFromScan,
                              style: FilledButton.styleFrom(
                                backgroundColor: kBrandGreen,
                              ),
                              child: const Text('加入群聊'),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_scanError.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _scanError,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),

                  _section('服务器与认证'),
                  TextField(
                    controller: _serverCtrl,
                    onChanged: (v) => _server = v,
                    decoration: const InputDecoration(hintText: '服务器地址'),
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _userCtrl,
                          onChanged: (v) => _user = v,
                          decoration: const InputDecoration(hintText: '用户名'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _passCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(hintText: '密码'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _saveServer,
                        child: const Text('保存配置'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _testing ? null : _testConnection,
                        child: Text(_testing ? '测试中…' : '测试连接'),
                      ),
                      if (_testResult.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Text(
                          _testResult,
                          style: TextStyle(
                            fontSize: 13,
                            color: _testResult.contains('✓')
                                ? kBrandGreen
                                : Colors.red,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 24),

                  _section('群聊管理（${_subs.length}）'),
                  if (_subs.isEmpty)
                    const Text(
                      '暂无群聊',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  for (final s in _subs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: avatarFor(s.topic).color,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text(avatarFor(s.topic).emoji),
                      ),
                      title: Text(
                        widget.displayName(s.topic),
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        s.topic,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        tooltip: '删除群聊',
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Colors.redAccent,
                        ),
                        onPressed: () => _deleteSub(s),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      '密信 v1.0.0 · 基于 ntfy 协议\nFlutter 全平台客户端',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
