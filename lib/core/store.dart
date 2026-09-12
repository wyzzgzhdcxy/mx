/// 跨平台持久化。
///
/// ## 存储选型说明
///
/// 桌面端原本用 SQLite（modernc.org/sqlite 纯 Go 实现）。Flutter 侧若沿用
/// SQLite 需要 sqlite3_flutter_libs + drift，在 Web 上还得切 WASM 方案，
/// 三套代码路径 —— 为一个"本地消息缓存"引入这么多东西不划算。
///
/// 这里改用**分片 JSON 文件**：
///  - 全平台同一套代码（Web 用 localStorage，其余用应用数据目录文件）
///  - 消息按主题分片落盘，避免单文件膨胀；每个分片只保留最近 N 条
///  - 写入走"临时文件 + rename"，保证不会因断电/崩溃留下半个文件
///
/// 唯一的取舍：没有 SQL 查询能力。但本应用的查询只有"按主题取最近 N 条"，
/// 内存过滤完全够用，不值得为此上数据库引擎。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';
import 'envelope.dart';
import 'models.dart';
import 'ntfy_api.dart' show generateSenderId;

/// 本地保存的一条聊天消息。
class MessageRec {
  MessageRec({
    required this.id,
    required this.time,
    required this.topic,
    this.title = '',
    this.body = '',
    this.priority = kPriorityDefault,
    this.tags = const [],
    this.from = '',
    this.mine = false,
    this.attachment,
    this.localPath = '',
  });

  final String id;

  /// Unix 秒。
  final int time;
  final String topic;
  final String title;
  final String body;
  final int priority;
  final List<String> tags;

  /// 来源服务器（同一主题可能订阅了多个服务器）。
  final String from;

  /// 是否本端所发 —— 决定气泡左右。
  final bool mine;

  final NtfyAttachment? attachment;

  /// 附件下载到本地后的路径（空表示尚未下载完成）。
  String localPath;

  MessageRec copyWith({
    String? title,
    String? body,
    int? priority,
    List<String>? tags,
    bool? mine,
    NtfyAttachment? attachment,
    String? localPath,
  }) {
    return MessageRec(
      id: id,
      time: time,
      topic: topic,
      title: title ?? this.title,
      body: body ?? this.body,
      priority: priority ?? this.priority,
      tags: tags ?? this.tags,
      from: from,
      mine: mine ?? this.mine,
      attachment: attachment ?? this.attachment,
      localPath: localPath ?? this.localPath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time,
    'topic': topic,
    'title': title,
    'body': body,
    'priority': priority,
    'tags': tags,
    'from': from,
    'mine': mine,
    if (attachment != null) 'attachment': attachment!.toJson(),
    'localPath': localPath,
  };

  factory MessageRec.fromJson(Map<String, dynamic> json) {
    NtfyAttachment? att;
    final raw = json['attachment'];
    if (raw is Map) {
      att = NtfyAttachment.fromJson(Map<String, dynamic>.from(raw));
    }
    return MessageRec(
      id: (json['id'] as String?) ?? '',
      time: (json['time'] as num?)?.toInt() ?? 0,
      topic: (json['topic'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      priority: (json['priority'] as num?)?.toInt() ?? kPriorityDefault,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      from: (json['from'] as String?) ?? '',
      mine: (json['mine'] as bool?) ?? false,
      attachment: att,
      localPath: (json['localPath'] as String?) ?? '',
    );
  }

  /// 唯一键：同一服务器同一主题下的同一消息 id。
  String get key => '$from|$topic|$id';
}

/// 一条订阅。
class SubRec {
  SubRec({
    required this.server,
    required this.topic,
    this.user = '',
    this.pass = '',
    this.token = '',
    required this.createdAt,
  });

  final String server;
  final String topic;
  final String user;
  final String pass;
  final String token;

  /// 订阅创建时间（unix 毫秒），用于稳定排序。
  final int createdAt;

  String get id => '$server|$topic';

  NtfyCredentials get creds =>
      NtfyCredentials(user: user, pass: pass, token: token);

  Map<String, dynamic> toJson() => {
    'server': server,
    'topic': topic,
    'user': user,
    'pass': pass,
    'token': token,
    'createdAt': createdAt,
  };

  factory SubRec.fromJson(Map<String, dynamic> json) => SubRec(
    server: (json['server'] as String?) ?? '',
    topic: (json['topic'] as String?) ?? '',
    user: (json['user'] as String?) ?? '',
    pass: (json['pass'] as String?) ?? '',
    token: (json['token'] as String?) ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
  );
}

/// 本地存储门面。所有读写都经过它。
class Store {
  Store._(this._dir, this._mem, this._memPrefs);

  final Directory? _dir;

  /// 内存缓存：避免同一会话内重复读盘。
  final Map<String, String> _mem;

  /// Web 端的真实后端（localStorage）。桌面/移动端为 null。
  final SharedPreferences? _memPrefs;

  /// 每个主题保留的消息条数上限。超过后丢弃最旧的。
  static const int _perTopicLimit = 2000;

  static const String _kSubsKey = 'mx.subs';
  static const String _kAliasesKey = 'mx.aliases';
  static const String _kSenderIdKey = 'mx.senderId';
  static const String _kServerPrefsKey = 'mx.serverPrefs';
  static const String _kLastTopicKey = 'mx.lastTopic';

  /// 打开存储。桌面/移动端用应用数据目录，Web 端用 SharedPreferences。
  static Future<Store> open() async {
    if (isWebPlatform) {
      final prefs = await SharedPreferences.getInstance();
      return Store._(null, {}, prefs);
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}mx-data');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return Store._(dir, {}, null);
  }

  // -------------------------------------------------------------------------
  // 底层读写
  // -------------------------------------------------------------------------

  Future<String?> _readRaw(String key) async {
    if (_mem.containsKey(key)) return _mem[key];
    if (_dir != null) {
      final f = File('${_dir.path}${Platform.pathSeparator}$key.json');
      if (await f.exists()) {
        try {
          return await f.readAsString();
        } on IOException {
          return null;
        }
      }
      return null;
    }
    return _memPrefs?.getString(key);
  }

  Future<void> _writeRaw(String key, String value) async {
    _mem[key] = value;
    if (_dir != null) {
      final target = File('${_dir.path}${Platform.pathSeparator}$key.json');
      final tmp = File('${target.path}.tmp');
      // 原子写：先写临时文件再 rename，避免崩溃留下半个 JSON
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(target.path);
      return;
    }
    await _memPrefs?.setString(key, value);
  }

  Future<void> _deleteRaw(String key) async {
    _mem.remove(key);
    if (_dir != null) {
      final f = File('${_dir.path}${Platform.pathSeparator}$key.json');
      if (await f.exists()) await f.delete();
      return;
    }
    await _memPrefs?.remove(key);
  }

  // -------------------------------------------------------------------------
  // 本机标识（sender id）
  // -------------------------------------------------------------------------

  /// 读取本机 16 位十六进制标识，不存在则生成并落盘。
  ///
  /// 这个标识是"左右气泡"的决定者，必须跨重启稳定。
  Future<String> loadOrCreateSenderId() async {
    final existing = await _readRaw(_kSenderIdKey);
    // 用同一套形状校验（16 位小写十六进制），避免把手工改坏的旧值继续用下去
    if (existing != null && isSenderId(existing.trim())) {
      return existing.trim();
    }
    final id = generateSenderId();
    await _writeRaw(_kSenderIdKey, id);
    return id;
  }

  Future<void> saveSenderId(String id) async {
    await _writeRaw(_kSenderIdKey, id.trim());
  }

  // -------------------------------------------------------------------------
  // 订阅
  // -------------------------------------------------------------------------

  Future<List<SubRec>> listSubs() async {
    final raw = await _readRaw(_kSubsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = list
          .map((e) => SubRec.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } on FormatException {
      return [];
    }
  }

  Future<void> saveSub(SubRec sub) async {
    final list = await listSubs();
    final idx = list.indexWhere(
      (s) => s.server == sub.server && s.topic == sub.topic,
    );
    if (idx >= 0) {
      // 已存在：保留原 createdAt（保证排序稳定），更新凭据
      list[idx] = SubRec(
        server: sub.server,
        topic: sub.topic,
        user: sub.user,
        pass: sub.pass,
        token: sub.token,
        createdAt: list[idx].createdAt,
      );
    } else {
      list.add(sub);
    }
    await _writeRaw(
      _kSubsKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> deleteSub(String server, String topic) async {
    final list = await listSubs();
    list.removeWhere((s) => s.server == server && s.topic == topic);
    await _writeRaw(
      _kSubsKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
    // 连带清掉该主题的本地消息
    await _deleteRaw('msgs_${_topicKey(server, topic)}');
  }

  // -------------------------------------------------------------------------
  // 群聊别名（群聊名称）
  // -------------------------------------------------------------------------

  Future<Map<String, String>> listAliases() async {
    final raw = await _readRaw(_kAliasesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map;
      return map.map((k, v) => MapEntry(k.toString(), v.toString()));
    } on FormatException {
      return {};
    }
  }

  Future<void> setAlias(String topic, String alias) async {
    final map = await listAliases();
    if (alias.trim().isEmpty) {
      map.remove(topic);
    } else {
      map[topic] = alias.trim();
    }
    await _writeRaw(_kAliasesKey, jsonEncode(map));
  }

  // -------------------------------------------------------------------------
  // 消息
  // -------------------------------------------------------------------------

  static String _topicKey(String server, String topic) {
    // 文件名不能含 : / \ 等字符，做一次可逆性无关的短哈希替换
    final s = '$server|$topic';
    return base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  }

  /// 读取某主题的本地消息（按时间正序）。
  Future<List<MessageRec>> listMessages(String server, String topic) async {
    final raw = await _readRaw('msgs_${_topicKey(server, topic)}');
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => MessageRec.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } on FormatException {
      return [];
    }
  }

  /// 读取全部主题的本地消息（"全部消息"视图用），按时间正序。
  Future<List<MessageRec>> listAllMessages(List<SubRec> subs) async {
    final all = <MessageRec>[];
    for (final s in subs) {
      all.addAll(await listMessages(s.server, s.topic));
    }
    all.sort((a, b) => a.time.compareTo(b.time));
    return all;
  }

  /// 保存一条消息（同 id 已存在则忽略，保证幂等）。
  Future<void> saveMessage(MessageRec rec) async {
    final key = 'msgs_${_topicKey(rec.from, rec.topic)}';
    final list = await listMessages(rec.from, rec.topic);
    if (list.any((m) => m.id == rec.id)) return;
    list.add(rec);
    list.sort((a, b) => a.time.compareTo(b.time));
    // 只保留最近 N 条，避免分片文件无限膨胀
    final trimmed = list.length > _perTopicLimit
        ? list.sublist(list.length - _perTopicLimit)
        : list;
    await _writeRaw(
      key,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  /// 批量保存（首次拉历史时用，减少写入次数）。
  Future<void> saveMessages(List<MessageRec> recs) async {
    if (recs.isEmpty) return;
    final byTopic = <String, List<MessageRec>>{};
    for (final r in recs) {
      byTopic.putIfAbsent('${r.from}|${r.topic}', () => []).add(r);
    }
    for (final entry in byTopic.entries) {
      final first = entry.value.first;
      final key = 'msgs_${_topicKey(first.from, first.topic)}';
      final list = await listMessages(first.from, first.topic);
      final existing = list.map((m) => m.id).toSet();
      for (final r in entry.value) {
        if (!existing.contains(r.id)) list.add(r);
      }
      list.sort((a, b) => a.time.compareTo(b.time));
      final trimmed = list.length > _perTopicLimit
          ? list.sublist(list.length - _perTopicLimit)
          : list;
      await _writeRaw(
        key,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    }
  }

  /// 回填附件的本地路径与真实大小（下载完成后调用）。
  Future<void> updateAttachment(
    String server,
    String topic,
    String messageId, {
    String? localPath,
    int? size,
  }) async {
    final list = await listMessages(server, topic);
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.id != messageId) continue;
      var att = m.attachment;
      if (att != null && size != null && size > 0 && att.size != size) {
        att = att.copyWith(size: size);
      }
      list[i] = m.copyWith(
        localPath: localPath ?? m.localPath,
        attachment: att,
      );
      changed = true;
      break;
    }
    if (!changed) return;
    await _writeRaw(
      'msgs_${_topicKey(server, topic)}',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  /// 本主题本地最后一条消息 id —— 重连时的增量起点。
  Future<String> lastMessageId(String server, String topic) async {
    final list = await listMessages(server, topic);
    if (list.isEmpty) return '';
    return list.last.id;
  }

  // -------------------------------------------------------------------------
  // 界面偏好
  // -------------------------------------------------------------------------

  Future<String> getLastTopic() async => (await _readRaw(_kLastTopicKey)) ?? '';

  Future<void> setLastTopic(String topic) async {
    await _writeRaw(_kLastTopicKey, topic);
  }

  Future<Map<String, dynamic>> getServerPrefs() async {
    final raw = await _readRaw(_kServerPrefsKey);
    if (raw == null || raw.isEmpty) {
      return {
        'server': kDefaultServer,
        'user': kDefaultUser,
        'pass': kDefaultPass,
      };
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } on FormatException {
      return {
        'server': kDefaultServer,
        'user': kDefaultUser,
        'pass': kDefaultPass,
      };
    }
  }

  Future<void> setServerPrefs(Map<String, dynamic> prefs) async {
    await _writeRaw(_kServerPrefsKey, jsonEncode(prefs));
  }
}

/// 编译期平台常量（与 ntfy_api.dart 中保持一致）。
const bool isWebPlatform = bool.fromEnvironment('dart.library.js_util');
