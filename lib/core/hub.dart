/// 订阅连接管理器（hub）。
///
/// 职责：
///  - 为每条订阅维护一条长连接，断线按退避策略自动重连
///  - 收到消息后：剥信封 → 判定归属 → 落库 → 广播给 UI
///  - 附件在后台并发下载（限流），进度/结果单独回传，不阻塞消息上屏
///
/// 设计上刻意把"网络层"与"UI"解耦：UI 只订阅 Stream，
/// 因此同一套代码在手机（前后台切换）、桌面（常驻）、Web（标签页）都能跑。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'constants.dart';
import 'envelope.dart';
import 'models.dart';
import 'ntfy_api.dart';
import 'store.dart';

/// 一条订阅的实时状态。
enum SubState { connecting, connected, reconnecting, stopped }

/// 连接状态变化事件。
class SubStateEvent {
  const SubStateEvent({
    required this.subId,
    required this.state,
    this.error,
  });

  final String subId;
  final SubState state;
  final String? error;
}

/// 附件下载进度事件。
class AttachmentEvent {
  const AttachmentEvent({
    required this.messageId,
    required this.topic,
    required this.state,
    this.received = 0,
    this.total = 0,
    this.error,
    this.localPath,
  });

  final String messageId;
  final String topic;

  /// downloading / done / failed
  final String state;
  final int received;
  final int total;
  final String? error;
  final String? localPath;

  double? get percent {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }
}

/// 一条订阅的运行时句柄。
class _SubHandle {
  _SubHandle({required this.sub, required this.creds});

  final SubRec sub;
  final NtfyCredentials creds;

  NtfySubscriptionStream? stream;
  StreamSubscription<String>? sub_;
  bool closed = false;

  /// 最后收到的消息 id —— 重连时作为 since，避免重复拉取。
  String lastId = '';

  /// 当前状态。
  SubState state = SubState.connecting;

  /// 连续失败次数，用于计算退避时长。
  int errorCount = 0;
}

/// 订阅管理器。
class Hub {
  Hub({required this.store, NtfyApi? api}) : _api = api ?? NtfyApi();

  final Store store;
  final NtfyApi _api;

  final Map<String, _SubHandle> _handles = {};

  /// 本机标识，决定气泡左右。
  String senderId = '';

  /// 当前活跃的附件下载数（并发闸门用）。
  int _activeDownloads = 0;

  // --- 事件流 ---

  final _messageCtrl = StreamController<MessageRec>.broadcast();
  final _stateCtrl = StreamController<SubStateEvent>.broadcast();
  final _attachCtrl = StreamController<AttachmentEvent>.broadcast();

  /// 新消息（含自己发的回流）流。
  Stream<MessageRec> get onMessage => _messageCtrl.stream;

  /// 连接状态变化流。
  Stream<SubStateEvent> get onState => _stateCtrl.stream;

  /// 附件进度流。
  Stream<AttachmentEvent> get onAttachment => _attachCtrl.stream;

  /// 重连退避序列（秒），与 Android 端 JsonConnection.RETRY_SECONDS 对齐。
  static const List<int> _retrySeconds = [5, 10, 15, 20, 30, 45, 60, 120];

  /// 初始化：读本机标识 + 恢复所有已保存订阅。
  Future<void> init() async {
    senderId = await store.loadOrCreateSenderId();
    final subs = await store.listSubs();
    for (final s in subs) {
      await subscribe(
        server: s.server,
        topic: s.topic,
        creds: s.creds,
        createdAt: s.createdAt,
        persist: false,
      );
    }
  }

  /// 订阅一条主题并启动长连接。
  Future<void> subscribe({
    required String server,
    required String topic,
    required NtfyCredentials creds,
    int? createdAt,
    bool persist = true,
  }) async {
    final normalized = NtfyApi.normalizeBaseUrl(
      server.isEmpty ? kDefaultServer : server,
    );
    if (!isValidTopic(topic)) {
      throw NtfyException(kInvalidTopicMessage);
    }
    final effectiveCreds = creds.orDefault();
    final now = DateTime.now().millisecondsSinceEpoch;

    if (persist) {
      await store.saveSub(
        SubRec(
          server: normalized,
          topic: topic,
          user: effectiveCreds.user,
          pass: effectiveCreds.pass,
          token: effectiveCreds.token,
          createdAt: createdAt ?? now,
        ),
      );
    }

    final id = '$normalized|$topic';
    // 已存在则先关掉旧的，避免重复连接
    if (_handles.containsKey(id)) {
      await unsubscribe(normalized, topic, persist: false);
    }

    final handle = _SubHandle(
      sub: SubRec(
        server: normalized,
        topic: topic,
        user: effectiveCreds.user,
        pass: effectiveCreds.pass,
        token: effectiveCreds.token,
        createdAt: createdAt ?? now,
      ),
      creds: effectiveCreds,
    );
    // 增量起点：本地已有历史时从最后一条之后继续
    handle.lastId = await store.lastMessageId(normalized, topic);

    _handles[id] = handle;
    unawaited(_runLoop(handle));
  }

  /// 取消一条订阅。
  Future<void> unsubscribe(
    String server,
    String topic, {
    bool persist = true,
  }) async {
    final id = '$server|$topic';
    final h = _handles.remove(id);
    if (h != null) {
      h.closed = true;
      await h.sub_?.cancel();
      await h.stream?.cancel();
      _emitState(h, SubState.stopped);
    }
    if (persist) {
      await store.deleteSub(server, topic);
    }
  }

  /// 当前全部订阅。
  List<SubRec> listSubs() => _handles.values.map((h) => h.sub).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// 某条订阅的当前状态。
  SubState stateOf(String server, String topic) =>
      _handles['$server|$topic']?.state ?? SubState.stopped;

  /// 关闭全部连接。
  Future<void> dispose() async {
    for (final h in _handles.values) {
      h.closed = true;
      await h.sub_?.cancel();
      await h.stream?.cancel();
    }
    _handles.clear();
    await _messageCtrl.close();
    await _stateCtrl.close();
    await _attachCtrl.close();
  }

  // -------------------------------------------------------------------------
  // 连接循环
  // -------------------------------------------------------------------------

  Future<void> _runLoop(_SubHandle h) async {
    while (!h.closed) {
      try {
        await _connectOnce(h);
        if (h.closed) break;
        // 连接被服务端正常关闭：短暂等待后重连
        _emitState(h, SubState.reconnecting, error: '连接已断开');
      } on NtfyException catch (e) {
        if (h.closed) break;
        h.errorCount++;
        _emitState(h, SubState.reconnecting, error: e.message);
      } on SocketException catch (e) {
        if (h.closed) break;
        h.errorCount++;
        _emitState(h, SubState.reconnecting, error: '网络不可达：${e.message}');
      } on Exception catch (e) {
        if (h.closed) break;
        h.errorCount++;
        _emitState(h, SubState.reconnecting, error: e.toString());
      }
      if (h.closed) break;
      final secs = _retrySeconds[
          h.errorCount.clamp(1, _retrySeconds.length) - 1];
      await Future<void>.delayed(Duration(seconds: secs));
    }
  }

  /// 建立一次连接并读到断开为止。
  Future<void> _connectOnce(_SubHandle h) async {
    final since = h.lastId.isNotEmpty ? h.lastId : kSinceAll;
    final stream = await _api.subscribe(
      baseUrl: h.sub.server,
      topic: h.sub.topic,
      since: since,
      creds: h.creds,
    );
    h.stream = stream;
    h.errorCount = 0;
    _emitState(h, SubState.connected);

    final done = Completer<void>();
    h.sub_ = stream.lines.listen(
      (line) => _onLine(h, line),
      onError: (Object e, StackTrace _) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );
    try {
      await done.future;
    } finally {
      h.sub_ = null;
    }
  }

  /// 处理一行内联 JSON 事件。
  void _onLine(_SubHandle h, String line) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return;
      json = decoded;
    } on FormatException {
      return; // 坏行跳过，不影响后续
    }

    final msg = NtfyMessage.fromJson(json);
    switch (msg.event) {
      case kEventOpen:
        // 连接就绪标记，无业务内容
        return;
      case kEventKeepalive:
        return;
      case kEventMessageDelete:
      case kEventMessageClear:
        // 服务端删除事件：本地暂不处理（消息保留在历史里）
        return;
      case kEventMessage:
        break;
      default:
        return;
    }

    _handleMessage(h, msg);
  }

  void _handleMessage(_SubHandle h, NtfyMessage msg) {
    // 推进增量起点，重连时不会重复拉取
    if (msg.id.isNotEmpty) h.lastId = msg.id;

    final rawBody = msg.message ?? '';

    // 归属判定：优先信封（权威），无信封时退回启发式
    final byEnvelope = resolveMineByEnvelope(rawBody, senderId);
    final mine = byEnvelope ?? false;

    // 剥信封：落库与上屏的都是干净正文
    final body = stripEnvelope(rawBody);

    final rec = MessageRec(
      id: msg.id,
      time: msg.time,
      topic: msg.topic,
      title: msg.title ?? '',
      body: body,
      priority: msg.priority ?? kPriorityDefault,
      tags: msg.tags ?? const [],
      from: h.sub.server,
      mine: mine,
      attachment: msg.attachment,
    );

    // 先落库再上屏：即使 UI 来不及渲染，重开也能看到
    unawaited(store.saveMessage(rec));
    if (!_messageCtrl.isClosed) _messageCtrl.add(rec);

    // 附件后台下载
    final att = msg.attachment;
    if (att != null && (att.url ?? '').isNotEmpty) {
      if (mine) {
        // 自己发的附件：服务器 echo 回来时不要再下一遍（本端必然已有）
        if (!_attachCtrl.isClosed) {
          _attachCtrl.add(
            AttachmentEvent(
              messageId: msg.id,
              topic: msg.topic,
              state: 'done',
              total: att.size ?? 0,
            ),
          );
        }
      } else {
        unawaited(_downloadAttachment(h, rec));
      }
    }
  }

  // -------------------------------------------------------------------------
  // 附件下载
  // -------------------------------------------------------------------------

  Future<void> _downloadAttachment(_SubHandle h, MessageRec rec) async {
    final att = rec.attachment;
    if (att == null || (att.url ?? '').isEmpty) return;
    if (att.size != null && att.size! > kMaxDownloadSize) {
      _emitAttach(
        AttachmentEvent(
          messageId: rec.id,
          topic: rec.topic,
          state: 'failed',
          error: '附件超过 ${kMaxDownloadSize >> 20}MB 上限',
        ),
      );
      return;
    }
    if (NtfyApi.kIsWeb) {
      // Web 端跨域下载受限，附件交给浏览器直链打开，这里不预下载
      _emitAttach(
        AttachmentEvent(
          messageId: rec.id,
          topic: rec.topic,
          state: 'done',
          total: att.size ?? 0,
        ),
      );
      return;
    }

    // 并发闸门：超过上限就排队等待
    while (_activeDownloads >= kMaxConcurrentDownloads) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (h.closed) return;
    }
    _activeDownloads++;

    _emitAttach(
      AttachmentEvent(
        messageId: rec.id,
        topic: rec.topic,
        state: 'downloading',
        total: att.size ?? 0,
      ),
    );

    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final path = await _attachmentPath(rec, att);
      final file = File(path);
      // 本地已有同名缓存 → 直接复用（重复消息不重复下载）
      if (await file.exists()) {
        final size = await file.length();
        await _finishAttachment(h, rec, path, size);
        return;
      }

      final tmp = File('$path.part');
      if (await tmp.exists()) await tmp.delete();
      final sink = tmp.openWrite();
      var received = 0;
      try {
        received = await _api.download(
          fileUrl: att.url!,
          creds: h.creds,
          onProgress: (got, total) {
            // 节流：200ms 一次，避免高频事件打爆 UI
            final now = DateTime.now();
            if (now.difference(lastReport).inMilliseconds < 200) return;
            lastReport = now;
            _emitAttach(
              AttachmentEvent(
                messageId: rec.id,
                topic: rec.topic,
                state: 'downloading',
                received: got,
                total: total > 0 ? total : (att.size ?? 0),
              ),
            );
          },
          onChunk: sink.add,
        );
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (received == 0) {
        await tmp.delete();
        throw NtfyException('附件内容为空');
      }
      // 原子落盘：写完才 rename，避免半个文件被当成缓存命中
      await tmp.rename(path);
      await _finishAttachment(h, rec, path, received);
    } on Exception catch (e) {
      _emitAttach(
        AttachmentEvent(
          messageId: rec.id,
          topic: rec.topic,
          state: 'failed',
          error: e is NtfyException ? e.message : e.toString(),
        ),
      );
    } finally {
      _activeDownloads--;
    }
  }

  Future<void> _finishAttachment(
    _SubHandle h,
    MessageRec rec,
    String path,
    int size,
  ) async {
    await store.updateAttachment(
      rec.from,
      rec.topic,
      rec.id,
      localPath: path,
      size: size,
    );
    _emitAttach(
      AttachmentEvent(
        messageId: rec.id,
        topic: rec.topic,
        state: 'done',
        received: size,
        total: size,
        localPath: path,
      ),
    );
  }

  /// 附件保存路径：`<appSupport>/mx-received/<消息id>_<清洗后的文件名>`。
  Future<String> _attachmentPath(MessageRec rec, NtfyAttachment att) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}mx-received');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = att.name.replaceAll(RegExp(r'[\\/:*?"<>| ]'), '_');
    final name = safe.isEmpty ? 'file.bin' : safe;
    return '${dir.path}${Platform.pathSeparator}${rec.id}_$name';
  }

  /// 收到附件保存目录（UI 里"打开文件夹"用）。
  Future<String> receivedDir() async {
    if (NtfyApi.kIsWeb) return '';
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}mx-received');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // -------------------------------------------------------------------------
  // 发布
  // -------------------------------------------------------------------------

  /// 发送一条文本消息到指定主题。
  ///
  /// 会向**所有已订阅该主题的服务器**发布（同一主题可能订阅了多个服务端）。
  Future<void> publishText({
    required String topic,
    required String message,
    String title = '',
    int priority = kPriorityDefault,
    List<String> tags = const [],
  }) async {
    final targets = _targetsFor(topic);
    if (targets.isEmpty) {
      throw NtfyException('尚未订阅该主题，无法发送');
    }
    final wire = packMessage(senderId, message);
    Object? lastError;
    var sent = 0;
    for (final h in targets) {
      try {
        await _api.publish(
          baseUrl: h.sub.server,
          topic: topic,
          message: wire,
          creds: h.creds,
          title: title,
          priority: priority,
          tags: tags,
          sender: senderId,
        );
        sent++;
      } on Exception catch (e) {
        lastError = e;
      }
    }
    if (sent == 0) {
      throw NtfyException(
        lastError is NtfyException
            ? (lastError).message
            : '发送失败：${lastError ?? '未知错误'}',
      );
    }
  }

  /// 发送一条带文件附件的消息。
  ///
  /// [bytes] 非空时走内存通道（上限 15MB）；否则 [filePath] 指向磁盘文件，
  /// 走流式读取通道（上限 1GB）。
  Future<void> publishAttachment({
    required String topic,
    required String message,
    required String filename,
    String mimeType = '',
    List<int>? bytes,
    String? filePath,
    String title = '',
    int priority = kPriorityDefault,
    List<String> tags = const [],
  }) async {
    final targets = _targetsFor(topic);
    if (targets.isEmpty) {
      throw NtfyException('尚未订阅该主题，无法发送');
    }
    List<int> data;
    if (bytes != null) {
      if (bytes.length > kMaxAttachmentSize) {
        throw NtfyException('文件超过 ${kMaxAttachmentSize >> 20}MB 限制');
      }
      data = bytes;
    } else if (filePath != null) {
      final f = File(filePath);
      if (!await f.exists()) throw NtfyException('读取文件失败：文件不存在');
      final size = await f.length();
      if (size == 0) throw NtfyException('文件内容为空');
      if (size > kMaxFileSize) {
        throw NtfyException('文件超过 ${kMaxFileSize >> 30}GB 限制');
      }
      data = await f.readAsBytes();
    } else {
      throw NtfyException('附件内容为空');
    }

    final wire = packMessage(senderId, message);
    Object? lastError;
    var sent = 0;
    for (final h in targets) {
      try {
        await _api.publish(
          baseUrl: h.sub.server,
          topic: topic,
          message: wire,
          creds: h.creds,
          title: title,
          priority: priority,
          tags: tags,
          body: data,
          mimeType: mimeType,
          filename: filename,
          sender: senderId,
        );
        sent++;
      } on Exception catch (e) {
        lastError = e;
      }
    }
    if (sent == 0) {
      throw NtfyException(
        lastError is NtfyException
            ? (lastError).message
            : '发送失败：${lastError ?? '未知错误'}',
      );
    }
  }

  List<_SubHandle> _targetsFor(String topic) {
    final seen = <String>{};
    final out = <_SubHandle>[];
    for (final h in _handles.values) {
      if (h.sub.topic != topic) continue;
      if (seen.contains(h.sub.server)) continue;
      seen.add(h.sub.server);
      out.add(h);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  void _emitState(_SubHandle h, SubState state, {String? error}) {
    h.state = state;
    if (_stateCtrl.isClosed) return;
    _stateCtrl.add(
      SubStateEvent(subId: h.sub.id, state: state, error: error),
    );
  }

  void _emitAttach(AttachmentEvent e) {
    if (_attachCtrl.isClosed) return;
    _attachCtrl.add(e);
  }
}
