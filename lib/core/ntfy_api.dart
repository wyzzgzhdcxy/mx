/// ntfy HTTP API 客户端 —— 全平台统一实现。
///
/// 覆盖协议的三条通道：
///  1. **发布** `POST /<topic>`：正文走 body，元数据走 X-* 请求头。
///  2. **订阅** `GET /<topic>/json?since=<id>`：长连接，逐行返回 JSON 事件。
///  3. **轮询** `GET /<topic>/json?poll=1&since=<id>`：拿完即断，用于保底。
///
/// 平台差异处理：桌面/移动端用 `dart:io HttpClient`（可控超时、不被系统代理干扰），
/// Web 端没有 dart:io，改用 `package:http` 的流式响应。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'constants.dart';
import 'models.dart';

/// 一条认证失败/内容过大/限流等可分类的错误。
class NtfyException implements Exception {
  NtfyException(this.message, {this.statusCode, this.apiError});

  final String message;
  final int? statusCode;
  final NtfyApiError? apiError;

  @override
  String toString() => message;
}

/// 附件消息的内容上限被服务端拒绝（413）。
class NtfyTooLargeException extends NtfyException {
  NtfyTooLargeException([String? msg])
    : super(msg ?? '文件太大被服务器拒绝（413）');
}

/// 订阅连接管理需要的"活动连接"抽象：能取消，能读流。
class NtfySubscriptionStream {
  NtfySubscriptionStream._(this._lineStream, this._cancel);

  final Stream<String> _lineStream;
  final Future<void> Function() _cancel;

  Stream<String> get lines => _lineStream;

  Future<void> cancel() => _cancel();
}

class NtfyApi {
  NtfyApi({http.Client? webClient}) : _webClient = webClient ?? http.Client();

  final http.Client _webClient;

  /// 订阅长连接专用 Http client：关闭 idle 超时，避免服务端静默连接被系统提前掐断。
  ///
  /// 注意**刻意不继承系统代理**：内网附件直传场景下，若 HTTP_PROXY 把
  /// 192.168.x.x 的 LAN 流量也发到外部代理，代理不认识该地址会主动断开，
  /// 表现为 EOF / unexpected EOF。浏览器有"跳过本地地址"开关，dart:io 没有。
  static final HttpClient _subscriberIoClient = () {
    final c = HttpClient();
    c.idleTimeout = const Duration(minutes: 30);
    c.connectionTimeout = const Duration(seconds: 20);
    c.findProxy = (uri) => 'DIRECT';
    return c;
  }();

  /// 默认 client：普通请求用，带系统代理（外网服务器走代理是合理需求）。
  static final HttpClient _defaultIoClient = () {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 20);
    c.idleTimeout = const Duration(seconds: 30);
    return c;
  }();

  /// 附件下载专用：不继承代理 + 5 分钟超时（与桌面端 downloadClient 对齐）。
  static final HttpClient _downloadIoClient = () {
    final c = HttpClient();
    c.idleTimeout = const Duration(minutes: 5);
    c.connectionTimeout = const Duration(seconds: 20);
    c.findProxy = (uri) => 'DIRECT';
    return c;
  }();

  // -------------------------------------------------------------------------
  // URL 构造
  // -------------------------------------------------------------------------

  /// 规范化 base url：补 scheme、去尾部斜杠。
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return kDefaultServer;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// `POST` 目标：`<base>/<topic>`。
  static String publishUrl(String baseUrl, String topic) =>
      '${normalizeBaseUrl(baseUrl)}/$topic';

  /// 长连接订阅：`<base>/<topic>/json?since=<since>`。
  static String subscribeUrl(String baseUrl, String topic, String since) =>
      '${normalizeBaseUrl(baseUrl)}/$topic/json?since=$since';

  /// 一次性轮询：加 `poll=1` 让服务端返回完历史立刻断开。
  static String pollUrl(String baseUrl, String topic, String since) =>
      '${normalizeBaseUrl(baseUrl)}/$topic/json?poll=1&since=$since';

  /// 标题等值要放进 URL query 时做百分号编码。
  static String _enc(String v) => Uri.encodeQueryComponent(v);

  /// 压掉 HTTP 头里不允许的字符（换行/回车/NUL）。
  ///
  /// 附件消息的正文与标题通过 X-Message / X-Title 头传输，值里带换行会让
  /// 整个请求以 "invalid header field value" 失败 —— 多行文本 + 附件就是这种情况。
  static String headerSafe(String s) {
    if (!s.contains('\r') && !s.contains('\n') && !s.contains('\x00')) {
      return s;
    }
    return s
        .replaceAll('\r\n', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll('\x00', '');
  }

  static void _applyAuth(Map<String, String> headers, NtfyCredentials creds) {
    if (creds.token.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${creds.token}';
    } else if (creds.user.isNotEmpty) {
      final basic = base64Encode(utf8.encode('${creds.user}:${creds.pass}'));
      headers['Authorization'] = 'Basic $basic';
    }
  }

  // -------------------------------------------------------------------------
  // 发布
  // -------------------------------------------------------------------------

  /// 发布一条文本消息。
  ///
  /// [message] 应当已经是**信封打包后**的线格式（调用方用 packMessage 处理）。
  /// 返回服务端分配的消息 id。
  Future<NtfyPublishReply> publish({
    required String baseUrl,
    required String topic,
    required String message,
    required NtfyCredentials creds,
    String title = '',
    int priority = kPriorityDefault,
    List<String> tags = const [],
    String click = '',
    String attach = '',
    String filename = '',
    bool markdown = false,
    List<int>? body,
    String mimeType = '',
    String sender = '',
  }) async {
    final url = publishUrl(baseUrl, topic);
    final headers = <String, String>{};
    _applyAuth(headers, creds);

    if (body != null) {
      // 附件通道：文件字节走 body，正文退回 query 参数（body 已被占用）
      headers['Content-Type'] = mimeType.isEmpty
          ? 'application/octet-stream'
          : mimeType;
      if (filename.isNotEmpty) headers['X-Filename'] = headerSafe(filename);
      if (message.isNotEmpty) headers['X-Message'] = headerSafe(message);
    } else {
      headers['Content-Type'] = 'text/plain; charset=utf-8';
    }

    if (title.isNotEmpty) headers['X-Title'] = headerSafe(title);
    if (priority >= kPriorityMin && priority <= kPriorityUrgent) {
      headers['X-Priority'] = '$priority';
    }
    if (tags.isNotEmpty) headers['X-Tags'] = tags.join(',');
    if (click.isNotEmpty) headers['X-Click'] = headerSafe(click);
    if (attach.isNotEmpty) headers['X-Attach'] = headerSafe(attach);
    if (markdown) headers['X-Markdown'] = 'true';
    if (sender.isNotEmpty) headers['X-Ntfy-Sender'] = sender;

    // 附件通道下正文改走 query，因为 body 被文件字节占用
    var finalUrl = url;
    if (body != null && message.isNotEmpty) {
      finalUrl = '$url?message=${_enc(message)}';
    }

    return _withRetry(() async {
      final resp = await _request(
        method: 'POST',
        url: finalUrl,
        headers: headers,
        body: body ?? utf8.encode(message),
        client: _defaultIoClient,
      );
      if (resp.statusCode == 413) {
        throw NtfyTooLargeException(
          '文件太大被服务器拒绝（413，服务端附件上限可能更小）',
        );
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw NtfyException('服务器返回 ${resp.statusCode}，可能需要认证',
            statusCode: resp.statusCode);
      }
      if (resp.statusCode != 200) {
        throw NtfyException(
          _describeError(resp),
          statusCode: resp.statusCode,
        );
      }
      final text = utf8.decode(resp.body, allowMalformed: true).trim();
      if (text.isEmpty) return const NtfyPublishReply(id: '');
      final json = jsonDecode(text) as Map<String, dynamic>;
      return NtfyPublishReply.fromJson(json);
    });
  }

  /// 409 限流重试：服务端给 Retry-After 就按它等，没有就指数退避。
  static const List<Duration> _retryBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    var wait = Duration.zero;
    Object? lastError;
    for (var attempt = 0; attempt <= _retryBackoff.length; attempt++) {
      if (attempt > 0 && wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      try {
        return await action();
      } on NtfyRateLimited catch (e) {
        lastError = e;
        wait = e.retryIn;
        if (wait <= Duration.zero && attempt < _retryBackoff.length) {
          wait = _retryBackoff[attempt];
        }
        const maxWait = Duration(seconds: 8);
        if (wait > maxWait) wait = maxWait;
      }
    }
    throw lastError ?? NtfyException('发送失败');
  }

  /// 解析响应体里的错误信息，拼成一句人话。
  String _describeError(_HttpResp resp) {
    final text = utf8.decode(resp.body, allowMalformed: true).trim();
    if (text.isNotEmpty) {
      try {
        final json = jsonDecode(text);
        if (json is Map<String, dynamic>) {
          final err = NtfyApiError.fromJson(json);
          if (err.error != null && err.error!.isNotEmpty) {
            return '服务器返回 ${resp.statusCode}：${err.error}';
          }
        }
      } on FormatException {
        // 不是 JSON，退化成状态码描述
      }
    }
    return '服务器返回 ${resp.statusCode}';
  }

  // -------------------------------------------------------------------------
  // 订阅（长连接）
  // -------------------------------------------------------------------------

  /// 打开长连接订阅。返回一个可取消、可逐行读取的流。
  ///
  /// [since] 为消息 id（增量起点）或 kSinceAll / kSinceNone。
  ///
  /// Web 平台走 package:http 的流式响应；其余平台走 dart:io。
  Future<NtfySubscriptionStream> subscribe({
    required String baseUrl,
    required String topic,
    required String since,
    required NtfyCredentials creds,
  }) async {
    final url = subscribeUrl(baseUrl, topic, since);
    final headers = <String, String>{'Accept': 'application/x-ndjson'};
    _applyAuth(headers, creds);

    if (kIsWeb) {
      return _subscribeWeb(url, headers);
    }
    return _subscribeIo(url, headers);
  }

  Future<NtfySubscriptionStream> _subscribeIo(
    String url,
    Map<String, String> headers,
  ) async {
    final req = await _subscriberIoClient.getUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    final resp = await req.close();

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      await resp.drain<void>();
      throw NtfyException(
        '服务器返回 ${resp.statusCode}，该群聊需要认证（请填写用户名密码或访问令牌）',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw NtfyException('订阅失败，服务器返回 ${resp.statusCode}',
          statusCode: resp.statusCode);
    }

    // 按行切分：ntfy 的 /json 端点每条事件一行 JSON。
    // 用 utf8.decoder 处理跨 TCP 包的多字节字符，避免中文被切成乱码。
    final controller = StreamController<String>();
    resp
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final t = line.trim();
            if (t.isNotEmpty) controller.add(t);
          },
          onError: controller.addError,
          onDone: controller.close,
          cancelOnError: false,
        );
    return NtfySubscriptionStream._(controller.stream, () async {
      await resp.detachSocket().then((s) => s.destroy()).catchError((_) {});
      if (!controller.isClosed) await controller.close();
    });
  }

  Future<NtfySubscriptionStream> _subscribeWeb(
    String url,
    Map<String, String> headers,
  ) async {
    final req = http.Request('GET', Uri.parse(url));
    headers.forEach((k, v) => req.headers[k] = v);
    final resp = await _webClient.send(req);

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw NtfyException(
        '服务器返回 ${resp.statusCode}，该群聊需要认证',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw NtfyException('订阅失败，服务器返回 ${resp.statusCode}',
          statusCode: resp.statusCode);
    }

    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim());
    return NtfySubscriptionStream._(lines, () async {});
  }

  // -------------------------------------------------------------------------
  // 轮询（保底通道）
  // -------------------------------------------------------------------------

  /// 一次性拉取 since 之后的消息，拿完即断。
  Future<List<NtfyMessage>> poll({
    required String baseUrl,
    required String topic,
    required String since,
    required NtfyCredentials creds,
  }) async {
    final url = pollUrl(baseUrl, topic, since);
    final headers = <String, String>{};
    _applyAuth(headers, creds);
    final resp = await _request(
      method: 'GET',
      url: url,
      headers: headers,
      client: _defaultIoClient,
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw NtfyException('服务器返回 ${resp.statusCode}，该群聊需要认证',
          statusCode: resp.statusCode);
    }
    if (resp.statusCode != 200) {
      throw NtfyException('轮询失败，服务器返回 ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final text = utf8.decode(resp.body, allowMalformed: true).trim();
    if (text.isEmpty) return const [];
    final out = <NtfyMessage>[];
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final json = jsonDecode(t);
        if (json is Map<String, dynamic>) {
          out.add(NtfyMessage.fromJson(json));
        }
      } on FormatException {
        continue; // 跳过坏行，不影响整批
      }
    }
    return out;
  }

  /// 检查某个主题是否可读（用于"订阅前先验证凭据"）。
  ///
  /// 老服务端没有 `/<topic>/auth` 端点，匿名访问会返回 404 —— 这种情况视为通过。
  Future<bool> checkAuth({
    required String baseUrl,
    required String topic,
    required NtfyCredentials creds,
  }) async {
    final url = '${normalizeBaseUrl(baseUrl)}/$topic/auth';
    final headers = <String, String>{};
    _applyAuth(headers, creds);
    final resp = await _request(
      method: 'GET',
      url: url,
      headers: headers,
      client: _defaultIoClient,
    );
    if (resp.statusCode == 200) return true;
    if (creds.user.isEmpty && resp.statusCode == 404) return true;
    if (resp.statusCode == 401 || resp.statusCode == 403) return false;
    throw NtfyException('服务器返回 ${resp.statusCode}');
  }

  /// 拉取服务端健康状态（设置页"测试连接"用）。
  Future<bool> health({required String baseUrl}) async {
    try {
      final url = '${normalizeBaseUrl(baseUrl)}/v1/health';
      final resp = await _request(
        method: 'GET',
        url: url,
        headers: const {},
        client: _defaultIoClient,
      );
      return resp.statusCode == 200;
    } on Exception {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 附件下载
  // -------------------------------------------------------------------------

  /// 流式下载附件到 [onChunk] 回调，返回实际字节数。
  ///
  /// [onProgress] 回报 (已收, 总大小)，总大小未知时传 0。
  Future<int> download({
    required String fileUrl,
    required NtfyCredentials creds,
    required void Function(List<int> chunk) onChunk,
    void Function(int received, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    if (kIsWeb) {
      // Web 端受 CORS 限制，附件下载走浏览器直链（见 UI 层处理）
      throw NtfyException('Web 平台请直接通过浏览器打开附件链接');
    }
    final req = await _downloadIoClient.getUrl(Uri.parse(fileUrl));
    final headers = <String, String>{};
    _applyAuth(headers, creds);
    headers.forEach(req.headers.set);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw NtfyException('下载失败，服务器返回 ${resp.statusCode}',
          statusCode: resp.statusCode);
    }
    final total = resp.contentLength > 0 ? resp.contentLength : 0;
    var received = 0;
    await for (final chunk in resp) {
      if (isCancelled != null && await isCancelled()) {
        throw NtfyException('已取消');
      }
      if (received + chunk.length > kMaxDownloadSize) {
        throw NtfyException('附件超过 ${kMaxDownloadSize >> 20}MB 上限，已中止');
      }
      onChunk(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    return received;
  }

  // -------------------------------------------------------------------------
  // 底层请求
  // -------------------------------------------------------------------------

  Future<_HttpResp> _request({
    required String method,
    required String url,
    required Map<String, String> headers,
    List<int>? body,
    required HttpClient client,
  }) async {
    final req = await client.openUrl(method, Uri.parse(url));
    headers.forEach(req.headers.set);
    if (body != null) req.add(body);
    final resp = await req.close();
    final bytes = await _collect(resp);
    return _HttpResp(
      statusCode: resp.statusCode,
      headers: resp.headers,
      body: bytes,
    );
  }

  Future<List<int>> _collect(HttpClientResponse resp) async {
    final chunked = <int>[];
    await for (final chunk in resp) {
      chunked.addAll(chunk);
    }
    return chunked;
  }

  /// 判断当前是否 Web 平台。用 `bool.fromEnvironment` 之外的方式：
  /// dart:io 在 web 上编译期就会被替换，所以这里用一个编译期常量。
  static const bool kIsWeb = bool.fromEnvironment('dart.library.js_util');
}

class _HttpResp {
  _HttpResp({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final dynamic headers;
  final List<int> body;
}

/// 服务端限流（429），携带建议的重试间隔。
class NtfyRateLimited extends NtfyException {
  NtfyRateLimited(this.retryIn) : super('发送太频繁，服务器限流（429）');

  final Duration retryIn;
}

/// 生成一个 8 字节随机数的 16 位十六进制标识（与 Android/桌面端同构）。
String generateSenderId() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(8, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 生成一个 64 字符的随机群聊 ID（与 Android/桌面端同构）。
String generateTopicId() {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < kTopicLength; i++) {
    buf.write(kTopicAlphabet[rnd.nextInt(kTopicAlphabet.length)]);
  }
  return buf.toString();
}
