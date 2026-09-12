/// 聊天页：气泡消息流 + 输入区。
///
/// 视觉与交互对齐桌面端 App.vue：左右气泡、头像、时间分隔标签、
/// 附件卡片、下载进度条、表情快捷栏、优先级选择。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/hub.dart';
import '../core/models.dart';
import '../core/ntfy_api.dart';
import '../core/store.dart';
import 'home_page.dart' show kAllTopics;
import 'theme.dart';

/// 气泡里附件的下载态（UI 侧状态，不落库）。
class _DlState {
  _DlState({required this.state, this.received = 0, this.total = 0, this.error});

  String state; // downloading / done / failed
  int received;
  int total;
  String? error;

  double? get percent => total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  String get label {
    if (state == 'failed') return '下载失败';
    if (total > 0) {
      return '${formatBytes(received)} / ${formatBytes(total)}';
    }
    return formatBytes(received);
  }
}

/// 待发送的附件。
///
/// 目前统一走磁盘路径通道（file_picker 选中的文件都有 path），
/// 内存字节通道留给将来的"粘贴图片"功能（Hub.publishAttachment 已支持）。
class _PendingAttach {
  _PendingAttach({
    required this.name,
    required this.size,
    this.path,
    this.mime = '',
    this.isImage = false,
  });

  final String name;
  final int size;
  final String? path;
  final String mime;
  final bool isImage;
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.hub,
    required this.store,
    required this.subs,
    required this.aliases,
    required this.activeTopic,
    required this.displayName,
    required this.onPickTopic,
    required this.onSubsChanged,
    required this.onOpenSettings,
    required this.onOpenAddGroup,
    required this.wide,
    required this.onRefreshAll,
    this.onBack,
  });

  final Hub hub;
  final Store store;
  final List<SubRec> subs;
  final Map<String, String> aliases;
  final String activeTopic;
  final String Function(String) displayName;
  final ValueChanged<String> onPickTopic;
  final Future<void> Function() onSubsChanged;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAddGroup;
  final bool wide;
  final VoidCallback? onBack;
  final Future<void> Function() onRefreshAll;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();

  final List<MessageRec> _messages = [];
  final Map<String, _DlState> _dl = {};
  final List<_PendingAttach> _pending = [];

  StreamSubscription<MessageRec>? _msgSub;
  StreamSubscription<AttachmentEvent>? _attSub;

  int _priority = kPriorityDefault;
  bool _sending = false;
  String _error = '';
  bool _stickToBottom = true;
  bool _showTopicMenu = false;

  static const List<String> _quickEmojis = ['😊', '👍', '🎉', '❤️', '😂', '🤔'];

  @override
  void initState() {
    super.initState();
    _msgSub = widget.hub.onMessage.listen(_onIncoming);
    _attSub = widget.hub.onAttachment.listen(_onAttachment);
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: false));
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _attSub?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final List<MessageRec> loaded;
    if (widget.activeTopic == kAllTopics) {
      loaded = await widget.store.listAllMessages(widget.subs);
    } else {
      // 同一主题可能订阅了多个服务器，逐个合并
      final merged = <MessageRec>[];
      for (final s in widget.subs) {
        if (s.topic != widget.activeTopic) continue;
        merged.addAll(await widget.store.listMessages(s.server, s.topic));
      }
      merged.sort((a, b) => a.time.compareTo(b.time));
      loaded = merged;
    }
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(loaded);
      // 历史里带本地路径的附件直接标记为已完成
      for (final m in loaded) {
        if (m.localPath.isNotEmpty) {
          _dl[m.recKey] = _DlState(state: 'done', total: m.attachment?.size ?? 0);
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: false));
  }

  /// 当前视图下应显示的消息。
  List<MessageRec> get _visible {
    if (widget.activeTopic == kAllTopics) return _messages;
    return _messages.where((m) => m.topic == widget.activeTopic).toList();
  }

  void _onIncoming(MessageRec rec) {
    if (!mounted) return;
    if (mounted) {
      setState(() {
        if (!_messages.any((m) => m.recKey == rec.recKey)) {
          _messages.add(rec);
          _messages.sort((a, b) => a.time.compareTo(b.time));
        }
      });
    }
    if (_stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _onAttachment(AttachmentEvent e) {
    if (!mounted) return;
    final key = _keyFor(e.topic, e.messageId);
    setState(() {
      if (e.state == 'done') {
        _dl[key] = _DlState(
          state: 'done',
          received: e.received,
          total: e.total,
        );
      } else if (e.state == 'failed') {
        _dl[key] = _DlState(state: 'failed', error: e.error);
      } else {
        _dl[key] = _DlState(
          state: 'downloading',
          received: e.received,
          total: e.total,
        );
      }
    });
  }

  /// 附件事件只带 topic + messageId，需要拼出与 MessageRec.recKey 一致的键。
  String _keyFor(String topic, String messageId) {
    // 找出该消息实际的 from（服务器），保证与 recKey 对齐
    for (final m in _messages) {
      if (m.id == messageId && m.topic == topic) return m.recKey;
    }
    return '|$topic|$messageId';
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollCtrl.hasClients) return;
    final target = _scrollCtrl.position.maxScrollExtent;
    if (animated) {
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scrollCtrl.jumpTo(target);
    }
  }

  // -------------------------------------------------------------------------
  // 发送
  // -------------------------------------------------------------------------

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    if (widget.activeTopic == kAllTopics) {
      setState(() => _error = '请先选择一个具体的群聊再发送');
      return;
    }

    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      if (_pending.isEmpty) {
        await widget.hub.publishText(
          topic: widget.activeTopic,
          message: text,
          priority: _priority,
        );
      } else {
        // 附件逐条发送：一条附件一条消息（与桌面端行为一致）
        for (final a in _pending) {
          await widget.hub.publishAttachment(
            topic: widget.activeTopic,
            message: text,
            filename: a.name,
            mimeType: a.mime,
            filePath: a.path,
            priority: _priority,
          );
        }
      }
      if (!mounted) return;
      _msgCtrl.clear();
      setState(() {
        _pending.clear();
        _sending = false;
      });
    } on NtfyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '发送失败：$e';
        _sending = false;
      });
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      setState(() {
        for (final f in result.files) {
          if (f.size > kMaxFileSize) {
            _error = '${f.name} 超过 1GB 限制，已跳过';
            continue;
          }
          _pending.add(
            _PendingAttach(
              name: f.name,
              size: f.size,
              path: f.path,
              mime: _mimeOf(f.name),
              isImage: _isImageName(f.name),
            ),
          );
        }
      });
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '选择文件失败：$e');
    }
  }

  static String _mimeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    return 'application/octet-stream';
  }

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  /// 粘贴：文本直接追加到输入框；剪贴板里是图片时，桌面端可从 file_picker 走不通，
  /// 这里给出明确提示（图片粘贴需要平台剪贴板读取原生支持，当前版本暂不支持）。
  Future<void> _handlePaste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      final sel = _msgCtrl.selection;
      final base = _msgCtrl.text;
      // 有选中就替换，没选中就追加到末尾
      final start = sel.isValid ? sel.start : base.length;
      final end = sel.isValid ? sel.end : base.length;
      final next = base.replaceRange(start, end, text);
      _msgCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + text.length),
      );
      return;
    }
    if (mounted) {
      setState(() {
        _error = '剪贴板里没有可粘贴的文本；发送图片请用左侧的附件按钮';
      });
    }
  }

  Future<void> _openAttachment(MessageRec m) async {
    final att = m.attachment;
    if (att == null) return;
    // 优先用本地缓存（已下载完的）
    final local = m.localPath;
    if (local.isNotEmpty && !NtfyApi.kIsWeb) {
      final f = File(local);
      if (await f.exists()) {
        await _openPath(local);
        return;
      }
    }
    final url = att.url;
    if (url == null || url.isEmpty) return;
    await _openUrl(url);
  }

  Future<void> _openPath(String path) async {
    try {
      final uri = Uri.file(path);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '打开文件失败：$e');
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      setState(() => _error = '无法打开链接');
    }
  }

  /// 在文件管理器中定位附件。
  Future<void> _revealAttachment(MessageRec m) async {
    final local = m.localPath;
    if (local.isEmpty || NtfyApi.kIsWeb) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,$local']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', local]);
      } else {
        await Process.run('xdg-open', [File(local).parent.path]);
      }
    } on Exception {
      // 定位失败不阻塞 UI
    }
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          if (_error.isNotEmpty) _errorBar(),
          Expanded(
            child: Container(
              color: isDark ? kChatBgDark : kChatBg,
              child: _buildMessageList(),
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canSwitch = widget.subs.isNotEmpty;
    return AppBar(
      leading: widget.onBack != null
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onBack,
            )
          : null,
      title: Stack(
        children: [
          Center(
            child: InkWell(
              onTap: canSwitch
                  ? () => setState(() => _showTopicMenu = !_showTopicMenu)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.displayName(widget.activeTopic),
                      style: const TextStyle(fontSize: 17),
                    ),
                    if (canSwitch) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_drop_down, size: 20),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '创建或加入群聊',
          icon: const Icon(Icons.add_circle_outline),
          onPressed: widget.onOpenAddGroup,
        ),
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: widget.onOpenSettings,
        ),
      ],
      bottom: _showTopicMenu && canSwitch
          ? PreferredSize(
              preferredSize: Size.fromHeight(
                (widget.subs.length + 1) * 42.0 + 8,
              ),
              child: Container(
                color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _menuItem('全部消息', kAllTopics),
                    for (final s in widget.subs)
                      _menuItem(widget.displayName(s.topic), s.topic),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _menuItem(String label, String topic) {
    final selected = widget.activeTopic == topic;
    return InkWell(
      onTap: () {
        setState(() => _showTopicMenu = false);
        widget.onPickTopic(topic);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? kBrandGreen : null,
          ),
        ),
      ),
    );
  }

  Widget _errorBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFEBEE),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error,
              style: const TextStyle(fontSize: 13, color: Colors.red),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _error = ''),
            child: const Icon(Icons.close, size: 16, color: Colors.red),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('💬', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
            Text(
              widget.subs.isEmpty
                  ? '还没有消息\n点击右上角 + 创建一个群聊'
                  : '这个群聊还没有消息\n收到或发送一条就会出现在这里',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification) {
          final pos = n.metrics;
          _stickToBottom = (pos.maxScrollExtent - pos.pixels) < 60;
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final m = visible[i];
          final prev = i > 0 ? visible[i - 1] : null;
          // 间隔超过 5 分钟才插时间标签，避免刷屏
          final showTime = prev == null || (m.time - prev.time) > 300;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showTime) _timeRow(m),
              _bubble(m, isAll: widget.activeTopic == kAllTopics),
            ],
          );
        },
      ),
    );
  }

  Widget _timeRow(MessageRec m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          formatMessageTime(m.time) +
              (widget.activeTopic == kAllTopics
                  ? ' · ${widget.displayName(m.topic)}'
                  : ''),
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _bubble(MessageRec m, {required bool isAll}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = m.mine;
    final av = avatarFor(m.topic);
    final dl = _dl[m.recKey];

    return Padding(
      padding: EdgeInsets.only(
        left: mine ? 56 : 12,
        right: mine ? 12 : 56,
        top: 3,
        bottom: 3,
      ),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            _avatar(av.emoji, av.color),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () => _showMessageMenu(m),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: mine
                      ? (isDark ? kBubbleMineDark : kBubbleMine)
                      : (isDark ? kBubbleOtherDark : kBubbleOther),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isAll && !mine)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          widget.displayName(m.topic),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    if (m.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          m.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (m.attachment != null) _attachmentWidget(m, dl),
                    if (m.body.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(
                          top: m.attachment != null ? 6 : 0,
                        ),
                        child: SelectableText(
                          m.body,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.35,
                            color: isDark && mine ? Colors.black87 : null,
                          ),
                        ),
                      ),
                    if (m.priority != kPriorityDefault ||
                        m.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 6,
                          children: [
                            if (m.priority != kPriorityDefault)
                              Text(
                                '❗${priorityLabel(m.priority)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.deepOrange,
                                ),
                              ),
                            for (final t in m.tags)
                              Text(
                                '#$t',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.blueGrey,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (mine) ...[
            const SizedBox(width: 8),
            _avatar('💻', kBrandGreen),
          ],
        ],
      ),
    );
  }

  Widget _avatar(String emoji, Color color) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(emoji, style: const TextStyle(fontSize: 18)),
    );
  }

  Widget _attachmentWidget(MessageRec m, _DlState? dl) {
    final att = m.attachment!;
    final hasLocal = m.localPath.isNotEmpty && !NtfyApi.kIsWeb;
    final showThumb =
        att.isImage && hasLocal && (dl == null || dl.state == 'done');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 整块可点：已下载则打开本地文件，否则退回远端链接
        GestureDetector(
          onTap: () => _openAttachment(m),
          child: showThumb
              // 本地缩略图：直接读文件，不占额外内存
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(m.localPath),
                    width: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _fileCard(att, hasLocal),
                  ),
                )
              : _fileCard(att, hasLocal),
        ),
        if (dl != null && dl.state == 'downloading')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: dl.percent,
                    minHeight: 4,
                    backgroundColor: Colors.black12,
                    color: kBrandGreen,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  dl.label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          )
        else if (dl != null && dl.state == 'failed')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '⚠ 下载失败：${dl.error ?? '未知原因'}',
              style: const TextStyle(fontSize: 11, color: Colors.red),
            ),
          ),
      ],
    );
  }

  Widget _fileCard(NtfyAttachment att, bool hasLocal) {
    // 点击行为由外层 `_attachmentWidget` 统一处理（打开本地文件或远端链接），
    // 这里只负责展示，避免内外两层都挂 onTap 造成重复触发。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            att.isImage ? '🖼' : (att.isVideo ? '🎬' : '📎'),
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              att.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (att.size != null && att.size! > 0) ...[
            const SizedBox(width: 6),
            Text(
              formatBytes(att.size!),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  void _showMessageMenu(MessageRec m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.body.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制文本'),
                onTap: () {
                  Navigator.pop(context);
                  _copyText(m.body);
                },
              ),
            if (m.attachment != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('打开附件'),
                onTap: () {
                  Navigator.pop(context);
                  _openAttachment(m);
                },
              ),
            if (m.localPath.isNotEmpty && !NtfyApi.kIsWeb)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('在文件夹中显示'),
                onTap: () {
                  Navigator.pop(context);
                  _revealAttachment(m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('消息 ID：${m.id}'),
              subtitle: Text('${formatDateTime(m.time)} · ${m.from}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canSend = widget.activeTopic != kAllTopics;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F7),
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white12 : Colors.black12,
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 工具栏：表情 + 附件 + 优先级
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  for (final e in _quickEmojis)
                    InkWell(
                      onTap: () {
                        _msgCtrl.text += e;
                        _msgCtrl.selection = TextSelection.fromPosition(
                          TextPosition(offset: _msgCtrl.text.length),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Text(e, style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '选择文件发送',
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.attach_file, size: 20),
                    visualDensity: VisualDensity.compact,
                  ),
                  const Spacer(),
                  DropdownButton<int>(
                    value: _priority,
                    underline: const SizedBox.shrink(),
                    isDense: true,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                    items: [
                      for (final p in kAllPriorities)
                        DropdownMenuItem(
                          value: p,
                          child: Text('优先级：${priorityLabel(p)}'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _priority = v);
                    },
                  ),
                ],
              ),
            ),
            if (_pending.isNotEmpty) _pendingRow(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      focusNode: _focusNode,
                      enabled: canSend,
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      // 粘贴：桌面端 Ctrl+V 走系统剪贴板，这里统一处理文本追加
                      onTapOutside: (_) => _focusNode.unfocus(),
                      decoration: InputDecoration(
                        hintText: canSend
                            ? '输入消息，Enter 发送'
                            : '请先在顶部选择群聊',
                        hintStyle: const TextStyle(fontSize: 13),
                        suffixIcon: IconButton(
                          tooltip: '粘贴文本',
                          icon: const Icon(Icons.content_paste, size: 18),
                          onPressed: _handlePaste,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending || !canSend ? null : _send,
                    style: FilledButton.styleFrom(
                      backgroundColor: kBrandGreen,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      minimumSize: const Size(0, 42),
                    ),
                    child: Text(_sending ? '发送中' : '发送'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingRow() {
    return SizedBox(
      height: 66,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (var i = 0; i < _pending.length; i++)
            Container(
              width: 150,
              margin: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black12),
              ),
              child: Row(
                children: [
                  Text(
                    _pending[i].isImage ? '🖼' : '📄',
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _pending[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          formatBytes(_pending[i].size),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _pending.removeAt(i)),
                    child: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// MessageRec 的唯一键扩展（与 Store 内部键一致）。
extension MessageRecKey on MessageRec {
  String get recKey => '$from|$topic|$id';
}
