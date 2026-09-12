/// ntfy 协议的数据模型。
///
/// 字段命名刻意与服务端 JSON 保持一致（含下划线风格），
/// 这样和 Android 端 Kotlin data class、桌面端 Go struct 三方对得上。
library;

/// 附件。
class NtfyAttachment {
  const NtfyAttachment({
    required this.name,
    this.type,
    this.size,
    this.expires,
    this.url,
  });

  final String name;
  final String? type;
  final int? size;
  final int? expires;
  final String? url;

  /// X-Attach 外链附件模式下，服务器没碰过文件本体，因此不含 size/type，
  /// 只能靠下载时的响应头与文件名扩展名补全。
  bool get isImage {
    if (type != null && type!.startsWith('image/')) return true;
    final lower = name.toLowerCase();
    for (final ext in const [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.avif',
    ]) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  /// 视频扩展名判定（用于决定气泡里是显示封面还是文件卡片）。
  bool get isVideo {
    if (type != null && type!.startsWith('video/')) return true;
    final lower = name.toLowerCase();
    for (final ext in const ['.mp4', '.mkv', '.mov', '.webm', '.avi', '.m4v']) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  factory NtfyAttachment.fromJson(Map<String, dynamic> json) {
    return NtfyAttachment(
      name: (json['name'] as String?) ?? '',
      type: json['type'] as String?,
      size: (json['size'] as num?)?.toInt(),
      expires: (json['expires'] as num?)?.toInt(),
      url: json['url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    if (type != null) 'type': type,
    if (size != null) 'size': size,
    if (expires != null) 'expires': expires,
    if (url != null) 'url': url,
  };

  NtfyAttachment copyWith({int? size, String? url}) => NtfyAttachment(
    name: name,
    type: type,
    size: size ?? this.size,
    expires: expires,
    url: url ?? this.url,
  );

  @override
  String toString() =>
      'NtfyAttachment($name, type=$type, size=$size, url=$url)';
}

/// 服务端推来的一条原始事件（message / open / keepalive ...）。
class NtfyMessage {
  const NtfyMessage({
    required this.id,
    required this.time,
    required this.event,
    required this.topic,
    this.title,
    this.message,
    this.priority,
    this.tags,
    this.attachment,
    this.click,
    this.icon,
    this.sender,
    this.contentType,
    this.encoding,
    this.sequenceId,
  });

  final String id;

  /// Unix 秒（服务端时区无关）。
  final int time;

  /// 事件类型，见 constants.dart 的 kEvent* 常量。
  final String event;

  final String topic;
  final String? title;
  final String? message;
  final int? priority;
  final List<String>? tags;
  final NtfyAttachment? attachment;
  final String? click;
  final String? icon;

  /// 服务端带的 sender 头（部分部署会填）。信封缺失时的兜底来源。
  final String? sender;

  final String? contentType;
  final String? encoding;
  final String? sequenceId;

  factory NtfyMessage.fromJson(Map<String, dynamic> json) {
    List<String>? tags;
    final rawTags = json['tags'];
    if (rawTags is List) {
      tags = rawTags.map((e) => e.toString()).toList();
    }
    final rawAtt = json['attachment'];
    NtfyAttachment? att;
    if (rawAtt is Map<String, dynamic>) {
      att = NtfyAttachment.fromJson(rawAtt);
    } else if (rawAtt is Map) {
      att = NtfyAttachment.fromJson(Map<String, dynamic>.from(rawAtt));
    }
    return NtfyMessage(
      id: (json['id'] as String?) ?? '',
      time: (json['time'] as num?)?.toInt() ?? 0,
      event: (json['event'] as String?) ?? '',
      topic: (json['topic'] as String?) ?? '',
      title: json['title'] as String?,
      message: json['message'] as String?,
      priority: (json['priority'] as num?)?.toInt(),
      tags: tags,
      attachment: att,
      click: json['click'] as String?,
      icon: json['icon'] as String?,
      sender: json['sender'] as String?,
      contentType: json['content_type'] as String?,
      encoding: json['encoding'] as String?,
      sequenceId: json['sequence_id'] as String?,
    );
  }
}

/// 发布响应：服务端返回消息 id / 时间 / 过期时间。
class NtfyPublishReply {
  const NtfyPublishReply({required this.id, this.time, this.expires});

  final String id;
  final int? time;
  final int? expires;

  factory NtfyPublishReply.fromJson(Map<String, dynamic> json) {
    return NtfyPublishReply(
      id: (json['id'] as String?) ?? '',
      time: (json['time'] as num?)?.toInt(),
      expires: (json['expires'] as num?)?.toInt(),
    );
  }
}

/// 服务端返回的错误体：`{"code":40001,"http":400,"error":"..."}`。
class NtfyApiError {
  const NtfyApiError({this.code, this.http, this.error});

  final int? code;
  final int? http;
  final String? error;

  factory NtfyApiError.fromJson(Map<String, dynamic> json) {
    return NtfyApiError(
      code: (json['code'] as num?)?.toInt(),
      http: (json['http'] as num?)?.toInt(),
      error: json['error'] as String?,
    );
  }
}

/// 一条订阅（服务器 + 主题）的访问凭据。
class NtfyCredentials {
  const NtfyCredentials({this.user = '', this.pass = '', this.token = ''});

  final String user;
  final String pass;

  /// 访问令牌（tk_ 开头），非空时优先于用户名密码。
  final String token;

  bool get isEmpty => user.isEmpty && token.isEmpty;

  /// 凭据为空时回落到默认账号 —— 与 Android / 桌面端行为一致。
  NtfyCredentials orDefault() {
    if (!isEmpty) return this;
    return const NtfyCredentials(user: 'admin', pass: 'wangchaojun');
  }

  Map<String, dynamic> toJson() => {'user': user, 'pass': pass, 'token': token};

  factory NtfyCredentials.fromJson(Map<String, dynamic> json) {
    return NtfyCredentials(
      user: (json['user'] as String?) ?? '',
      pass: (json['pass'] as String?) ?? '',
      token: (json['token'] as String?) ?? '',
    );
  }
}
