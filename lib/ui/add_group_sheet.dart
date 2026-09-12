/// 创建 / 加入群聊弹窗。
///
/// 三种加入方式（与 Android 端一致）：
///  1. 创建新群聊：本地生成 64 字符群聊 ID + 一个名称，写入订阅
///  2. 输入群聊 ID 加入：把 ID 作为主题订阅
///  3. 扫码加入：粘贴二维码里的内容自动解析
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/constants.dart';
import '../core/hub.dart';
import '../core/models.dart';
import '../core/ntfy_api.dart';
import '../core/store.dart';
import 'theme.dart';

/// 二维码 payload 协议：
///  - 完整 HTTP(S) 主题链接：`http://host/topic`
///  - 自定义 scheme：`mx://host/topic`
///  - 纯群聊 ID（64 位以内）
class QrPayload {
  const QrPayload({required this.server, required this.topic});

  final String server;
  final String topic;
}

/// 解析二维码内容。解析失败返回 null。
QrPayload? parseQrPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // mx:// 或 http(s):// 形式
  for (final scheme in ['mx://', 'http://', 'https://']) {
    if (text.startsWith(scheme)) {
      var rest = text.substring(scheme.length);
      // 去掉 http(s) 的 host 后的路径部分作为 topic
      final slash = rest.indexOf('/');
      if (slash <= 0) return null;
      final host = rest.substring(0, slash);
      final topic = rest.substring(slash + 1);
      if (!isValidTopic(topic)) return null;
      final server = scheme == 'mx://' ? 'http://$host' : '$scheme$host';
      return QrPayload(server: server, topic: topic);
    }
  }

  // 纯群聊 ID
  if (isValidTopic(text)) {
    return QrPayload(server: kDefaultServer, topic: text);
  }
  return null;
}

/// 生成二维码内容：优先用带 scheme 的短形式，方便跨端识别。
String buildQrPayload(String server, String topic) {
  final host = NtfyApi.normalizeBaseUrl(server)
      .replaceFirst('http://', '')
      .replaceFirst('https://', '');
  return 'mx://$host/$topic';
}

class AddGroupSheet extends StatefulWidget {
  const AddGroupSheet({super.key, required this.hub, required this.store});

  final Hub hub;
  final Store store;

  @override
  State<AddGroupSheet> createState() => _AddGroupSheetState();
}

class _AddGroupSheetState extends State<AddGroupSheet> {
  final _nameCtrl = TextEditingController();
  final _topicCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  int _tab = 0; // 0=创建 1=加入
  bool _busy = false;
  String _error = '';

  /// 创建成功后展示的群聊信息（用于分享二维码）。
  String? _createdTopic;
  String? _createdAlias;

  @override
  void initState() {
    super.initState();
    _loadServerPrefs();
  }

  Future<void> _loadServerPrefs() async {
    final prefs = await widget.store.getServerPrefs();
    if (!mounted) return;
    setState(() {
      _serverCtrl.text = (prefs['server'] as String?) ?? kDefaultServer;
      _userCtrl.text = (prefs['user'] as String?) ?? kDefaultUser;
      _passCtrl.text = (prefs['pass'] as String?) ?? kDefaultPass;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _topicCtrl.dispose();
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写群聊名称');
      return;
    }
    final server = NtfyApi.normalizeBaseUrl(_serverCtrl.text);
    final creds = NtfyCredentials(
      user: _userCtrl.text.trim(),
      pass: _passCtrl.text,
    );

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // 本地生成 64 字符随机群聊 ID，与 Android / 桌面端一致
      final topic = generateTopicId();
      await widget.hub.subscribe(
        server: server,
        topic: topic,
        creds: creds,
      );
      await widget.store.setAlias(topic, name);
      await widget.store.setServerPrefs({
        'server': server,
        'user': creds.user,
        'pass': creds.pass,
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _createdTopic = topic;
        _createdAlias = name;
      });
    } on NtfyException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '创建失败：$e';
      });
    }
  }

  Future<void> _joinGroup() async {
    final parsed = parseQrPayload(_topicCtrl.text.trim());
    if (parsed == null) {
      setState(() => _error = kInvalidTopicMessage);
      return;
    }
    final server = _serverCtrl.text.trim().isEmpty
        ? parsed.server
        : NtfyApi.normalizeBaseUrl(_serverCtrl.text);
    final creds = NtfyCredentials(
      user: _userCtrl.text.trim(),
      pass: _passCtrl.text,
    );

    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.hub.subscribe(
        server: server,
        topic: parsed.topic,
        creds: creds,
      );
      await widget.store.setServerPrefs({
        'server': server,
        'user': creds.user,
        'pass': creds.pass,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
    } on NtfyException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '加入失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: EdgeInsets.only(bottom: bottom),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (_createdTopic != null)
                  _buildCreatedView()
                else ...[
                  Row(
                    children: [
                      _tabButton('创建群聊', 0),
                      _tabButton('加入群聊', 1),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_tab == 0) ..._buildCreateForm() else ..._buildJoinForm(),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        _error,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final selected = _tab == index;
    return InkWell(
      onTap: () => setState(() {
        _tab = index;
        _error = '';
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        margin: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? kBrandGreen : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? kBrandGreen : null,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCreateForm() {
    return [
      const Text(
        '群聊名称（创建后会生成一个群聊 ID，分享给同伴即可一起聊天）',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _nameCtrl,
        decoration: const InputDecoration(hintText: '如：技术交流群'),
        maxLength: 64,
        onSubmitted: (_) => _createGroup(),
      ),
      const SizedBox(height: 4),
      _serverFields(),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _createGroup,
        style: FilledButton.styleFrom(
          backgroundColor: kBrandGreen,
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        child: Text(_busy ? '创建中…' : '创建'),
      ),
    ];
  }

  List<Widget> _buildJoinForm() {
    return [
      const Text(
        '粘贴群聊 ID、主题链接或 mx:// 链接，也可以用「设置」里的扫码功能识别二维码',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _topicCtrl,
        decoration: const InputDecoration(
          hintText: '群聊 ID / http://host/topic / mx://host/topic',
        ),
        maxLines: 2,
        minLines: 1,
      ),
      const SizedBox(height: 4),
      _serverFields(),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _joinGroup,
        style: FilledButton.styleFrom(
          backgroundColor: kBrandGreen,
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        child: Text(_busy ? '加入中…' : '加入'),
      ),
    ];
  }

  Widget _serverFields() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: const Text('服务器与认证（可选）', style: TextStyle(fontSize: 13)),
      children: [
        TextField(
          controller: _serverCtrl,
          decoration: const InputDecoration(hintText: '服务器地址'),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _userCtrl,
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
      ],
    );
  }

  /// 创建成功视图：展示群聊 ID 与邀请二维码。
  Widget _buildCreatedView() {
    final topic = _createdTopic!;
    final prefs = _serverCtrl.text;
    final payload = buildQrPayload(prefs, topic);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.check_circle, color: kBrandGreen, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '「$_createdAlias」创建成功',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: QrImageView(
              data: payload,
              size: 180,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Center(
          child: Text(
            '让同伴扫描此二维码即可加入群聊',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 16),
        const Text('群聊 ID', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.black12),
          ),
          child: SelectableText(
            topic,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: topic));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('群聊 ID 已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制 ID'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: payload));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('邀请链接已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.link, size: 16),
                label: const Text('复制链接'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: kBrandGreen,
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
